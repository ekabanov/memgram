import Foundation
import GRDB
@testable import Memgram

/// Bundles one simulated "device" for tests: in-memory DB + MeetingStore + CloudSyncEngine + FakeSyncTransport.
struct TestSyncEnvironment {
    let db: AppDatabase
    let meetingStore: MeetingStore
    let engine: CloudSyncEngine
    let transport: FakeSyncTransport

    /// Create a test environment connected to a shared FakeCloudKitChannel.
    static func make(channel: FakeCloudKitChannel) throws -> TestSyncEnvironment {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        let db = try AppDatabase(queue: queue)

        let transport = FakeSyncTransport(channel: channel)
        let engine = CloudSyncEngine(db: db, transport: transport)
        let store = MeetingStore(db: db, syncProvider: { engine })

        return TestSyncEnvironment(db: db, meetingStore: store, engine: engine, transport: transport)
    }

    /// Create a standalone test environment (no sync, for single-DB tests).
    static func makeLocal() throws -> TestSyncEnvironment {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        let db = try AppDatabase(queue: queue)

        let channel = FakeCloudKitChannel()
        let transport = FakeSyncTransport(channel: channel)
        let engine = CloudSyncEngine(db: db, transport: transport)
        let store = MeetingStore(db: db, syncProvider: { engine })

        return TestSyncEnvironment(db: db, meetingStore: store, engine: engine, transport: transport)
    }
}
