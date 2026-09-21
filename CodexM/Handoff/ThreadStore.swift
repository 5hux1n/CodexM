import Foundation
import SQLite3

/// Only read-only connections. No source database copies, writes, checkpoints or migrations.
actor ThreadStore {
    func readThreads(profile: Profile, root: URL) throws -> [ThreadMetadata] {
        let home = profile.codexHome(in: root).standardizedFileURL
        let url = home.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { throw CodexMError.handoffNoDatabase }
        guard url.resolvingSymlinksInPath().path == url.path else { throw CodexMError.unsafePath }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw CodexMError.handoffDatabase
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 700)
        let columns = try rows(db, "PRAGMA table_info(threads)").compactMap { $0.count > 1 ? $0[1] : nil }
        let required: Set<String> = ["id", "title", "cwd", "updated_at", "rollout_path"]
        guard required.isSubset(of: Set(columns)) else { throw CodexMError.handoffSchema }
        let archived = columns.contains("archived") ? "archived" : "0"
        let name = columns.contains("name") ? "name" : "NULL"
        let values = try rows(db, "SELECT id, title, cwd, rollout_path, updated_at, \(archived), \(name) FROM threads ORDER BY updated_at DESC LIMIT 500")
        return values.compactMap { row in
            guard row.count == 7, !row[0].isEmpty, row[2].hasPrefix("/"), !row[3].isEmpty else { return nil }
            let time = Double(row[4]) ?? 0
            let name = row[6].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty ? row[1] : name
            return ThreadMetadata(profileID: profile.id, threadID: row[0], title: SecretRedactor.clean(title).text,
                cwd: row[2], rolloutPath: row[3], updatedAt: Date(timeIntervalSince1970: time > 10_000_000_000 ? time / 1000 : time), archived: row[5] == "1")
        }
    }
    private func rows(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CodexMError.handoffSchema }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw CodexMError.handoffDatabase }
            result.append((0..<sqlite3_column_count(statement)).map { index in
                guard let bytes = sqlite3_column_text(statement, index) else { return "" }
                // Bound unexpected values from an evolving schema.
                let count = min(Int(sqlite3_column_bytes(statement, index)), 16_384)
                return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            })
        }
    }
}
