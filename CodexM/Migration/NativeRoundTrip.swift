import Foundation
import CryptoKit
import SQLite3

/// Single-writer history transfer. A destination must be a prefix of the
/// current owner's history; divergent branches are never overwritten.
enum NativeRoundTrip {
    static func relation(source: URL, target: URL, threadID: String) throws -> Bool {
        let latest = try NativeRolloutReader(source), previous = try NativeRolloutReader(target)
        func next(_ reader: NativeRolloutReader) throws -> Data? {
            while let line = try reader.next() {
                guard let row = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw NativeMigrationError.incompatible }
                if row["type"] as? String == "event_msg", let payload = row["payload"] as? [String: Any],
                   payload["type"] as? String == "thread_settings_applied", payload["thread_id"] as? String == threadID { continue }
                return Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])))
            }
            return nil
        }
        var compared = false
        while let before = try next(previous) {
            compared = true
            guard try next(latest) == before else { throw NativeMigrationError.diverged }
        }
        guard compared else { throw NativeMigrationError.invalid }
        return try next(latest) == nil
    }

    /// Discover all copies, including renamed or unindexed files. Ambiguous
    /// duplicates must be resolved without touching either copy.
    static func destination(home: URL, inventory: [String: String], threadID: String) throws -> String? {
        var matches: [String] = []
        for key in inventory.keys.sorted() where (key.hasPrefix("sessions/") || key.hasPrefix("archived_sessions/")) && key.hasSuffix(".jsonl") {
            let file = try FileHandle(forReadingFrom: home.appendingPathComponent(key)); defer { try? file.close() }
            let first = try file.read(upToCount: 1024 * 1024) ?? Data()
            guard let end = first.firstIndex(of: 10), let row = try JSONSerialization.jsonObject(with: first[..<end]) as? [String: Any],
                  row["type"] as? String == "session_meta", let meta = row["payload"] as? [String: Any] else { throw NativeMigrationError.incompatible }
            if meta["id"] as? String == threadID { matches.append(key) }
        }
        guard matches.count <= 1 else { throw NativeMigrationError.conflict }
        return matches.first
    }

    private static let knownTables: Set<String> = ["thread_turns", "thread_items", "thread_history_projection_state", "thread_realtime_items"]
    static func projectionTables(home: URL) throws -> [String] {
        let db = home.appendingPathComponent("thread_history_1.sqlite")
        guard NativeFiles.fm.fileExists(atPath: db.path) else { return [] }
        let tables = try NativeFiles.stoppedDatabaseRows(db, "SELECT name FROM sqlite_master WHERE type='table'", diagnosticStage: "targetSchema").map { $0[0] }
        var result: [String] = []
        for table in tables {
            // Only identifiers from sqlite_master, validated before interpolation.
            guard table.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { throw NativeMigrationError.incompatible }
            let columns = try NativeFiles.stoppedDatabaseRows(db, "PRAGMA table_info(\(table))", diagnosticStage: "targetSchema").map { $0[1] }
            if columns.contains("thread_id") {
                guard knownTables.contains(table) else { throw NativeMigrationError.incompatible }
                result.append(table)
            } else if knownTables.contains(table) { throw NativeMigrationError.incompatible }
        }
        return result.sorted()
    }

    /// Clear only reconstructible projections of this task. State/project
    /// metadata and every unrelated task stay in place. The official loader
    /// rebuilds and verifies these projections from the complete replacement.
    static func resetProjection(home: URL, threadID: String, tables: [String]) throws {
        guard !tables.isEmpty else { return }
        guard Set(tables).isSubset(of: knownTables) else { throw NativeMigrationError.incompatible }
        var db: OpaquePointer?
        let url = home.appendingPathComponent("thread_history_1.sqlite")
        try NativeFiles.safe(url)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw NativeMigrationError.helper
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw NativeMigrationError.busy }
        do {
            for table in tables {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE thread_id=?", -1, &statement, nil) == SQLITE_OK else { throw NativeMigrationError.incompatible }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                guard sqlite3_bind_text(statement, 1, threadID, -1, transient) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw NativeMigrationError.helper }
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw NativeMigrationError.helper }
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }
}

/// Bounded JSONL reader for long conversations. A partial final record is
/// rejected; at most one record plus a small read buffer is retained.
final class NativeRolloutReader {
    static let maxBytes = 1024 * 1024 * 1024
    private let file: FileHandle
    private var pending = Data()
    private var offset = 0
    private var ended = false
    init(_ url: URL) throws {
        try NativeFiles.safe(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= Self.maxBytes else { throw NativeMigrationError.invalid }
        file = try FileHandle(forReadingFrom: url)
    }
    deinit { try? file.close() }
    func next() throws -> Data? {
        while true {
            if let end = pending[offset...].firstIndex(of: 10) {
                guard end - offset <= 64 * 1024 * 1024 else { throw NativeMigrationError.invalid }
                let line = Data(pending[offset..<end]); offset = end + 1
                if offset >= 65536 { pending.removeSubrange(..<offset); offset = 0 }
                return line
            }
            if ended {
                guard offset == pending.count else { throw NativeMigrationError.changed }
                return nil
            }
            guard pending.count - offset <= 64 * 1024 * 1024 else { throw NativeMigrationError.invalid }
            let data = try file.read(upToCount: 65536) ?? Data()
            if data.isEmpty { ended = true } else { pending.append(data) }
        }
    }
}
