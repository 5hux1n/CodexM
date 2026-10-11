import Foundation
import Darwin
import SQLite3

// Minimal error adapter for compiling the real store without the app UI/journal.
enum CodexMError: Error {
    case unsafePath, storageLocked, corruptStorage, defaultAccountProtected, profileBusy, directoryNotEmpty, invalidName, filesystemError
}
enum AppFailure {
    static func capture(_ error: Error, operation: String) -> Error { error }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double?] = []
    func append(_ value: Double?) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [Double?] { lock.lock(); defer { lock.unlock() }; return values }
}

@main struct ProfileRelocationTests {
    static func blocked(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected occupancy rejection") }
        catch CodexMError.profileBusy { }
        catch { fatalError("Unexpected error: \(error)") }
    }
    static func main() async throws {
        try SingletonLockPolicy.validate(target: "OLD-host-999", localHostname: "new-host", localVolume: true) { _ in false }
        try SingletonLockPolicy.validate(target: "MINI.local-999", localHostname: "mini.local") { _ in false }
        blocked { try SingletonLockPolicy.validate(target: "old-host-999", localHostname: "new-host") { _ in false } }
        blocked { try SingletonLockPolicy.validate(target: "old-host-999", localHostname: "new-host", localVolume: true) { _ in true } }
        for target in ["broken", "-999", "host-0", "host-noPID"] {
            blocked { try SingletonLockPolicy.validate(target: target, localHostname: "new-host", localVolume: true) { _ in false } }
        }
        let fm = FileManager.default
        if CommandLine.arguments.contains("--check-current-locks") {
            // Read metadata and lock links only; no lease, save, launch or migration.
            let actualRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexM")
            let actualState = try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: actualRoot.appendingPathComponent("profiles.json")))
            let actualStore = ProfileStore(root: actualRoot)
            for actualProfile in actualState.profiles where !actualProfile.isInstalledDefault {
                try await actualStore.assertNotLocked(actualProfile)
            }
            print("PASS: read-only current account lock checks (\(actualState.profiles.filter { !$0.isInstalledDefault }.count) profiles)")
        }
        let sandbox = fm.temporaryDirectory.appendingPathComponent("CodexM-relocation-\(UUID())")
        defer { try? fm.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("manager")
        let destination = sandbox.appendingPathComponent("moved")
        let store = ProfileStore(root: root)
        _ = try await store.load()
        let profile = Profile(id: UUID(), name: "Fixture", createdAt: Date())
        try await store.prepare(profile)
        let historyHome = profile.codexHome(in: root)
        let historyDB = historyHome.appendingPathComponent("state_5.sqlite")
        let session = historyHome.appendingPathComponent("sessions/2026/10/01/rollout-fixture.jsonl")
        let archive = historyHome.appendingPathComponent("archived_sessions/rollout-archive.jsonl")
        for (url, id) in [(session, "fixture"), (archive, "archive")] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let meta: [String: Any] = ["type": "session_meta", "payload": ["id": id]]
            var data = try JSONSerialization.data(withJSONObject: meta)
            data.append(10)
            try data.write(to: url)
        }
        func sql(_ file: URL, _ query: String) throws {
            var db: OpaquePointer?
            precondition(sqlite3_open(file.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            precondition(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK)
        }
        try sql(historyDB, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT); INSERT INTO threads VALUES ('fixture', '\(session.path)', 'kept'), ('archive', '/obsolete/codex/archived_sessions/rollout-archive.jsonl', 'archived'), ('missing', '/obsolete/codex/sessions/rollout-missing.jsonl', 'missing');")
        func historyPaths(_ file: URL) -> [String: String] {
            var db: OpaquePointer?, statement: OpaquePointer?
            precondition(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            defer { sqlite3_close(db) }
            guard sqlite3_prepare_v2(db, "SELECT id, rollout_path FROM threads", -1, &statement, nil) == SQLITE_OK else { fatalError("\(file.path): \(String(cString: sqlite3_errmsg(db)))") }
            defer { sqlite3_finalize(statement) }
            var result: [String: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                result[String(cString: sqlite3_column_text(statement, 0))] = String(cString: sqlite3_column_text(statement, 1))
            }
            return result
        }
        let originalPaths = historyPaths(historyDB)
        let fixture = profile.codexHome(in: root).appendingPathComponent("fixture.txt")
        try Data("fixture-data".utf8).write(to: fixture)
        // Get a definitely exited PID rather than assuming a large PID is absent.
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        let lock = profile.electronHome(in: root).appendingPathComponent("SingletonLock")
        let stale = "old-machine.local-\(child.processIdentifier)"
        try fm.createSymbolicLink(atPath: lock.path, withDestinationPath: stale)
        let largeFile = profile.codexHome(in: root).appendingPathComponent("large.bin")
        try Data(repeating: 0x5a, count: 16 * 1024 * 1024).write(to: largeFile)
        let progress = ProgressRecorder()
        var state = StoredState(); state.profiles = [profile, .installedDefault(name: "Default")]
        try await store.save(state)
        let moved = try await store.relocateAccounts(to: destination, saving: state) { progress.append($0) }
        let samples = progress.snapshot()
        let fractions = samples.compactMap { $0 }
        precondition(samples.first! == nil && fractions.last == 1)
        precondition(fractions.contains { $0 > 0 && $0 < 1 })
        precondition(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        let relocated = moved.profiles[0]
        let newHome = relocated.codexHome(in: root)
        let newDB = newHome.appendingPathComponent("state_5.sqlite")
        let paths = historyPaths(newDB)
        precondition(paths["fixture"] == newHome.appendingPathComponent("sessions/2026/10/01/rollout-fixture.jsonl").path)
        precondition(paths["archive"] == newHome.appendingPathComponent("archived_sessions/rollout-archive.jsonl").path)
        precondition(paths["missing"] == originalPaths["missing"])
        precondition(historyPaths(historyDB) == originalPaths)
        // A wrong session identity rejects the move and leaves metadata/source intact.
        let badHome = sandbox.appendingPathComponent("bad")
        try fm.copyItem(at: newHome, to: badHome)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"wrong\"}}\n".utf8).write(to: badHome.appendingPathComponent("sessions/2026/10/01/rollout-fixture.jsonl"))
        do { try RelocatedHistory.rebase(home: badHome); fatalError("Accepted mismatched history") }
        catch CodexMError.corruptStorage { }
        precondition(historyPaths(badHome.appendingPathComponent("state_5.sqlite")) == paths)
        print("PASS: active/archive path rebasing, prior relocation paths, missing-file preservation, source database preservation, identity failure rollback")
        let movedLarge = try Data(contentsOf: relocated.codexHome(in: root).appendingPathComponent("large.bin"))
        precondition(movedLarge == Data(repeating: 0x5a, count: 16 * 1024 * 1024))
        let copiedData = try Data(contentsOf: relocated.codexHome(in: root).appendingPathComponent("fixture.txt"))
        precondition(copiedData == Data("fixture-data".utf8))
        precondition(fm.fileExists(atPath: fixture.path))
        let oldLock = try fm.destinationOfSymbolicLink(atPath: lock.path)
        let newLock = relocated.electronHome(in: root).appendingPathComponent("SingletonLock")
        precondition(oldLock == stale)
        precondition((try? fm.destinationOfSymbolicLink(atPath: newLock.path)) == nil)
        precondition(!fm.fileExists(atPath: newLock.path))
        precondition(moved.profiles[1] == state.profiles[1])
        precondition(moved.preferences.accountDataDirectory == destination.path)
        // Existing accounts are repaired at launch, not just during relocation.
        try sql(newDB, "UPDATE threads SET rollout_path='\(session.path)' WHERE id='fixture';")
        let beforeLaunchRepair = historyPaths(newDB)
        var walWriter: OpaquePointer?
        precondition(sqlite3_open(newDB.path, &walWriter) == SQLITE_OK)
        precondition(sqlite3_exec(walWriter, "PRAGMA journal_mode=WAL; UPDATE threads SET title='WAL preserved' WHERE id='fixture';", nil, nil, nil) == SQLITE_OK)
        try await store.repairHistoryBeforeLaunch(relocated)
        sqlite3_close(walWriter)
        precondition(historyPaths(newDB)["fixture"] == paths["fixture"])
        let backups = try fm.contentsOfDirectory(at: newHome, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("history-path-backup-") }
        precondition(backups.count == 1)
        precondition(historyPaths(backups[0].appendingPathComponent("state_5.sqlite")) == beforeLaunchRepair)
        let backupMode = try fm.attributesOfItem(atPath: backups[0].appendingPathComponent("state_5.sqlite").path)[.posixPermissions] as? NSNumber
        precondition(backupMode?.intValue == 0o600)
        try await store.repairHistoryBeforeLaunch(relocated)
        let again = try fm.contentsOfDirectory(at: newHome, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("history-path-backup-") }
        precondition(again.count == 1)
        print("PASS: existing-account launch repair, WAL-aware private backup, idempotent second launch")
        let relocatedLock = relocated.electronHome(in: root).appendingPathComponent("SingletonLock")
        try fm.createSymbolicLink(atPath: relocatedLock.path, withDestinationPath: "old-machine.local-\(getpid())")
        do { try await store.repairHistoryBeforeLaunch(relocated); fatalError("Repaired a live-locked account") }
        catch CodexMError.profileBusy { }
        do {
            _ = try await store.relocateAccounts(to: sandbox.appendingPathComponent("blocked"), saving: moved)
            fatalError("Moved a live-locked profile")
        } catch CodexMError.profileBusy { }
        precondition(!fm.fileExists(atPath: sandbox.appendingPathComponent("blocked").path))
        print("PASS: byte progress preparation/intermediate/completion and monotonicity")
        print("PASS: stale renamed-host locks, remote/unknown host rejection, live PID rejection, fixture relocation, retained backup/original lock and fresh destination IPC and protected default account")
    }
}
