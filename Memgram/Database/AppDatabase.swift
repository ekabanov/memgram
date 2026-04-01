import Foundation
import GRDB
import OSLog

private let dbLog = Logger.make("Database")

final class AppDatabase {
    static let shared: AppDatabase = {
        if let db = try? AppDatabase() { return db }
        // First open failed — database may be corrupt. Rename it and start fresh.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbURL = appSupport.appendingPathComponent("Memgram/memgram.db")
        let backupName = "memgram.db.corrupted-\(Int(Date().timeIntervalSince1970))"
        let backupURL = appSupport.appendingPathComponent("Memgram/\(backupName)")
        try? FileManager.default.moveItem(at: dbURL, to: backupURL)
        dbLog.critical("Database corrupted — moved to \(backupName, privacy: .public), starting fresh")
        do { return try AppDatabase() }
        catch { fatalError("[AppDatabase] Cannot open database even after recovery: \(error)") }
    }()

    private let dbQueue: DatabaseQueue
    private(set) var needsCloudResync = false

    private init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Memgram")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var config = Configuration()
        config.journalMode = .wal
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbQueue = try DatabaseQueue(
            path: dir.appendingPathComponent("memgram.db").path,
            configuration: config
        )
        try runMigrations()
    }

    // MARK: - Access

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    @discardableResult
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    // MARK: - Migrations

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "meetings") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("started_at", .double).notNull()
                t.column("ended_at", .double)
                t.column("duration_seconds", .double)
                t.column("status", .text).notNull().defaults(to: "recording")
                t.column("summary", .text)
                t.column("action_items", .text)
                t.column("raw_transcript", .text)
            }
            try db.create(table: "segments") { t in
                t.column("id", .text).primaryKey()
                t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("channel", .text).notNull()
                t.column("start_seconds", .double).notNull()
                t.column("end_seconds", .double).notNull()
                t.column("text", .text).notNull()
            }
            try db.create(table: "speakers") { t in
                t.column("id", .text).primaryKey()
                t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("custom_name", .text)
            }
            try db.create(table: "embeddings") { t in
                t.column("id", .text).primaryKey()
                t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("chunk_text", .text).notNull()
                t.column("embedding", .blob).notNull()
                t.column("model", .text).notNull()
            }
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.content = "segments"
                t.contentRowID = "rowid"
                t.column("text")
                t.column("speaker")
            }
            try db.execute(sql: """
                CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                    INSERT INTO segments_fts(rowid, text, speaker)
                    VALUES (new.rowid, new.text, new.speaker);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                    VALUES ('delete', old.rowid, old.text, old.speaker);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                    VALUES ('delete', old.rowid, old.text, old.speaker);
                    INSERT INTO segments_fts(rowid, text, speaker)
                    VALUES (new.rowid, new.text, new.speaker);
                END
            """)
        }

        migrator.registerMigration("v2_cloudkit_sync") { db in
            try db.alter(table: "meetings") { t in t.add(column: "ck_system_fields", .blob) }
            try db.alter(table: "segments") { t in t.add(column: "ck_system_fields", .blob) }
            try db.alter(table: "speakers") { t in t.add(column: "ck_system_fields", .blob) }
        }

        migrator.registerMigration("v3_calendar_fields") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "calendar_event_id", .text)
                t.add(column: "calendar_context", .text)
            }
        }

        migrator.registerMigration("v4_semantic_status") { db in
            // Nuke all data and recreate with sync_status + diarizing/interrupted status support.
            // Data is re-downloaded from CloudKit; AppDelegate clears CKSyncEngineState before start().
            try db.execute(sql: "DROP TRIGGER IF EXISTS segments_au")
            try db.execute(sql: "DROP TRIGGER IF EXISTS segments_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS segments_ai")
            try db.execute(sql: "DROP TABLE IF EXISTS segments_fts")
            try db.execute(sql: "DROP TABLE IF EXISTS embeddings")
            try db.execute(sql: "DROP TABLE IF EXISTS speakers")
            try db.execute(sql: "DROP TABLE IF EXISTS segments")
            try db.execute(sql: "DROP TABLE IF EXISTS meetings")

            try db.create(table: "meetings") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("started_at", .double).notNull()
                t.column("ended_at", .double)
                t.column("duration_seconds", .double)
                t.column("status", .text).notNull().defaults(to: "done")
                t.column("sync_status", .text).notNull().defaults(to: "pending_upload")
                t.column("summary", .text)
                t.column("action_items", .text)
                t.column("raw_transcript", .text)
                t.column("ck_system_fields", .blob)
                t.column("calendar_event_id", .text)
                t.column("calendar_context", .text)
            }
            try db.create(table: "segments") { t in
                t.column("id", .text).primaryKey()
                t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("channel", .text).notNull()
                t.column("start_seconds", .double).notNull()
                t.column("end_seconds", .double).notNull()
                t.column("text", .text).notNull()
                t.column("ck_system_fields", .blob)
            }
            try db.create(table: "speakers") { t in
                t.column("id", .text).primaryKey()
                t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("custom_name", .text)
                t.column("ck_system_fields", .blob)
            }
            try db.create(table: "embeddings") { t in
                t.column("id", .text).primaryKey()
                t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("chunk_text", .text).notNull()
                t.column("embedding", .blob).notNull()
                t.column("model", .text).notNull()
            }
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.content = "segments"
                t.contentRowID = "rowid"
                t.column("text")
                t.column("speaker")
            }
            try db.execute(sql: """
                CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                    INSERT INTO segments_fts(rowid, text, speaker)
                    VALUES (new.rowid, new.text, new.speaker);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                    VALUES ('delete', old.rowid, old.text, old.speaker);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                    VALUES ('delete', old.rowid, old.text, old.speaker);
                    INSERT INTO segments_fts(rowid, text, speaker)
                    VALUES (new.rowid, new.text, new.speaker);
                END
            """)
        }

        // Detect if v4 was just applied so AppDelegate can clear CloudKit sync state
        let appliedBefore = Set((try? dbQueue.read { try migrator.appliedIdentifiers($0) }) ?? [])
        try migrator.migrate(dbQueue)
        let appliedAfter = Set((try? dbQueue.read { try migrator.appliedIdentifiers($0) }) ?? [])
        // Only set on upgrade (not fresh install) — appliedBefore is empty on first launch
        if appliedAfter.contains("v4_semantic_status")
            && !appliedBefore.contains("v4_semantic_status")
            && appliedBefore.contains("v1_initial_schema") {
            needsCloudResync = true
        }
    }
}
