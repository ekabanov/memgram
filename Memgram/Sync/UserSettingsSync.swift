import CloudKit
import Foundation
import OSLog

/// Direct CloudKit sync for cross-device user settings.
/// Bypasses CKSyncEngine (like AudioChunkService) — a single well-known record
/// of type `UserSettings` in MemgramZone holds settings shared by Mac and iPhone.
///
/// Currently synced: `selectedCalendarKeys` — the user's calendar selection as
/// stable `"{source title}|{calendar title}"` keys. Raw `EKCalendar.calendarIdentifier`
/// values are NEVER synced: they are not stable across devices.
final class UserSettingsSync {
    static let shared = UserSettingsSync()

    private let log = Logger.make("UserSettings")
    private let container = CKContainer(identifier: "iCloud.com.memgram.app")
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "MemgramZone")

    private init() {}

    static let recordType = "UserSettings"
    static let recordName = "usersettings"
    static let calendarKeysField = "selectedCalendarKeys"

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName, zoneID: zoneID)
    }

    /// Push the selected-calendar keys to CloudKit. Last writer wins:
    /// on a `serverRecordChanged` conflict the server record is taken, our
    /// field is set on it, and it is saved once more. Fails soft — errors are
    /// logged, never thrown (the local UserDefaults value remains the source
    /// of truth on this device).
    func push(keys: [String]) async {
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: Self.recordType, recordID: recordID)
        } catch {
            // e.g. not signed into iCloud, network down, record type missing
            // from the production schema — fail soft.
            log.warning("UserSettings fetch-before-push failed: \(error)")
            return
        }
        record[Self.calendarKeysField] = keys as CKRecordValue
        do {
            try await save(record)
            log.info("Pushed calendar selection (\(keys.count) key(s))")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another device wrote concurrently — take the server record and
            // re-save once (last writer wins).
            guard let server = error.serverRecord else {
                log.warning("UserSettings conflict without server record — dropping push")
                return
            }
            server[Self.calendarKeysField] = keys as CKRecordValue
            do {
                try await save(server)
                log.info("Pushed calendar selection after conflict (\(keys.count) key(s))")
            } catch {
                log.error("UserSettings conflict re-save failed: \(error)")
            }
        } catch {
            log.error("UserSettings push failed: \(error)")
        }
    }

    /// Fetch the selected-calendar keys from CloudKit.
    /// Returns nil when the record doesn't exist yet or on any error
    /// (e.g. record type not deployed to the production schema) — callers
    /// keep their local value. An existing record with no field value is
    /// an empty selection (= all calendars).
    func fetch() async -> [String]? {
        do {
            let record = try await database.record(for: recordID)
            return record[Self.calendarKeysField] as? [String] ?? []
        } catch let error as CKError where error.code == .unknownItem {
            return nil  // no settings record yet — nothing to apply
        } catch {
            log.warning("UserSettings fetch failed: \(error)")
            return nil
        }
    }

    /// Save a single record; per-record failures arrive in the results
    /// dictionary (not as thrown errors), so they must be surfaced explicitly.
    private func save(_ record: CKRecord) async throws {
        let (saveResults, _) = try await database.modifyRecords(saving: [record], deleting: [])
        for (_, result) in saveResults {
            if case .failure(let error) = result {
                throw error
            }
        }
    }
}
