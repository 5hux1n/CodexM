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

/// Paginated forks refer to immutable prefixes of older rollout generations.
/// Materialize those prefixes in a private copy; never rewrite the source.
enum NativePortableRollout {
    struct Snapshot {
        let rollout: URL
        let inputs: [URL: String]
        let referenceHome: URL?
        func validate() throws {
            for (url, hash) in inputs where try NativeFiles.hash(url) != hash { throw NativeMigrationError.changed }
        }
    }
    static func prepare(_ source: URL, home: URL, workspace: URL) throws -> Snapshot {
        func header(_ file: URL) throws -> [String: Any] {
            let reader = try NativeRolloutReader(file)
            guard let line = try reader.next(), let row = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  row["type"] as? String == "session_meta", row["payload"] is [String: Any] else { throw NativeMigrationError.invalid }
            return row
        }
        var top = try header(source)
        var meta = top["payload"] as! [String: Any]
        let sourceHash = try NativeFiles.hash(source)
        guard meta["history_base"] != nil && !(meta["history_base"] is NSNull) else {
            return Snapshot(rollout: source, inputs: [source: sourceHash], referenceHome: nil)
        }
        try NativeFiles.directory(workspace)
        let output = workspace.appendingPathComponent(source.lastPathComponent)
        try NativeFiles.safe(output)
        guard NativeFiles.fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw NativeMigrationError.invalid }
        let writer = try FileHandle(forWritingTo: output); defer { try? writer.close() }
        var written = 0, outputOrdinal = 0
        let paginated = meta["history_mode"] as? String == "paginated"
        func emit(_ input: Data) throws {
            var data = input
            if paginated {
                guard var row = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { throw NativeMigrationError.invalid }
                row["ordinal"] = outputOrdinal
                data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            }
            outputOrdinal += 1
            written += data.count + 1
            guard written <= NativeRolloutReader.maxBytes else { throw NativeMigrationError.invalid }
            try writer.write(contentsOf: data); try writer.write(contentsOf: Data([10]))
        }
        // Provenance remains; only the storage dependency is removed.
        meta.removeValue(forKey: "history_base")
        meta.removeValue(forKey: "forked_from_ordinal_exclusive")
        top["payload"] = meta
        try emit(JSONSerialization.data(withJSONObject: top, options: [.sortedKeys]))
        var inputs: [URL: String] = [:], active: Set<URL> = []
        let reference = workspace.appendingPathComponent("reference")
        try NativeFiles.directory(reference)
        func resolve(_ id: String) throws -> URL {
            guard UUID(uuidString: id) != nil else { throw NativeMigrationError.historyBase }
            var matches: [URL] = []
            for folder in ["sessions", "archived_sessions"] {
                let directory = home.appendingPathComponent(folder)
                guard NativeFiles.fm.fileExists(atPath: directory.path) else { continue }
                var failed = false
                guard let iterator = NativeFiles.fm.enumerator(at: directory, includingPropertiesForKeys: nil, errorHandler: { _,_ in failed = true; return false }) else { throw NativeMigrationError.historyBase }
                for case let file as URL in iterator {
                    try NativeFiles.safe(file)
                    if file.lastPathComponent.hasSuffix("-\(id).jsonl") || file.lastPathComponent.hasSuffix("_\(id).jsonl") { matches.append(file.resolvingSymlinksInPath().standardizedFileURL) }
                }
                guard !failed else { throw NativeMigrationError.historyBase }
            }
            guard matches.count == 1 else { throw NativeMigrationError.historyBase }
            return matches[0]
        }
        // Ordinals count every physical record, including each generation's
        // metadata. Byte offsets are local to that generation's file.
        func append(_ input: URL, cutoff: (bytes: Int, ordinal: Int)?, depth: Int) throws -> Int {
            let file = input.resolvingSymlinksInPath().standardizedFileURL
            guard depth < 32, active.insert(file).inserted else { throw NativeMigrationError.historyBase }
            defer { active.remove(file) }
            let hash = try NativeFiles.hash(file); inputs[file] = hash
            let row = try header(file), payload = row["payload"] as! [String: Any]
            var ordinal = 0
            if let base = payload["history_base"], !(base is NSNull) {
                guard let base = base as? [String: Any], let id = base["thread_id"] as? String,
                      let bytes = base["end_byte_offset"] as? Int, let count = base["end_ordinal_exclusive"] as? Int,
                      bytes > 0, bytes <= NativeRolloutReader.maxBytes, count > 0, count <= NativeRolloutReader.maxBytes else { throw NativeMigrationError.historyBase }
                ordinal = try append(resolve(id), cutoff: (bytes, count), depth: depth + 1)
            }
            let reader = try NativeRolloutReader(file)
            var bytes = 0, index = 0
            while cutoff == nil || bytes < cutoff!.bytes {
                guard let line = try reader.next() else {
                    if cutoff != nil { throw NativeMigrationError.historyBase }; break
                }
                if payload["history_mode"] as? String == "paginated" {
                    guard let item = try JSONSerialization.jsonObject(with: line) as? [String: Any], item["ordinal"] as? Int == ordinal else { throw NativeMigrationError.historyBase }
                }
                bytes += line.count + 1; ordinal += 1
                guard cutoff == nil || bytes <= cutoff!.bytes else { throw NativeMigrationError.historyBase }
                if index > 0 { try emit(line) }
                index += 1
            }
            if let cutoff { guard bytes == cutoff.bytes, ordinal == cutoff.ordinal else { throw NativeMigrationError.historyBase } }
            guard try NativeFiles.hash(file) == hash else { throw NativeMigrationError.changed }
            // Retain the exact dependency graph for an independent official
            // loader comparison before allowing any target write.
            let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
            let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(homePath + "/") else { throw NativeMigrationError.historyBase }
            let copy = reference.appendingPathComponent(String(filePath.dropFirst(homePath.count + 1)))
            try NativeFiles.copy(file, to: copy)
            guard try NativeFiles.hash(copy) == hash else { throw NativeMigrationError.changed }
            return ordinal
        }
        _ = try append(source, cutoff: nil, depth: 0)
        try writer.synchronize()
        let snapshot = Snapshot(rollout: output, inputs: inputs, referenceHome: reference)
        try snapshot.validate()
        guard inputs[source.resolvingSymlinksInPath().standardizedFileURL] == sourceHash else { throw NativeMigrationError.changed }
        return snapshot
    }
}
