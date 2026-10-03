import Foundation
import CryptoKit
import SQLite3
import Darwin

enum NativeFiles {
    static var fm: FileManager { FileManager() }
    static func safe(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw CodexMError.unsafePath }
    }
    static func directory(_ url: URL) throws {
        try safe(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func hash(_ url: URL) throws -> String {
        try safe(url)
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard v.isRegularFile == true else { throw NativeMigrationError.invalid }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try safe(url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    // Only thread storage. Authentication, config, plugins, and Electron are excluded.
    static func included(_ relative: String) -> Bool {
        let first = relative.split(separator: "/").first.map(String.init) ?? ""
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return false }
        if ["sessions", "archived_sessions"].contains(first) { return true }
        guard !relative.contains("/") else { return false }
        return first == "session_index.jsonl" || first.range(of: #"^(?:state_5|thread_history_1|goals_1|logs_2|memories_1|queue_1)\.sqlite(?:-wal|-shm|-journal)?$"#, options: .regularExpression) != nil
    }
    /// Stores that define task history. Auxiliary logs, queues and memories
    /// have a separate lifecycle and cannot determine whether history imported.
    static func taskDatabase(_ name: String) -> Bool {
        ["state_5.sqlite", "thread_history_1.sqlite", "goals_1.sqlite"].contains(name)
    }
    static func inventory(_ home: URL) throws -> [String: String] {
        try safe(home)
        guard fm.fileExists(atPath: home.path) else { return [:] }
        var result: [String: String] = [:], bytes: Int64 = 0
        let tops = try fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey])
        for top in tops where included(top.lastPathComponent) {
            try safe(top)
            let values = try top.resourceValues(forKeys: [.isDirectoryKey])
            var files = [top]
            if values.isDirectory == true {
                var enumerationFailed = false
                guard ["sessions", "archived_sessions"].contains(top.lastPathComponent), let iterator = fm.enumerator(at: top, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw NativeMigrationError.invalid }
                files = []
                for case let url as URL in iterator {
                    try safe(url)
                    let v = try url.resourceValues(forKeys: [.isDirectoryKey])
                    if v.isDirectory != true { files.append(url) }
                }
                if enumerationFailed { throw NativeMigrationError.invalid }
            }
            for file in files {
                let v = try file.resourceValues(forKeys: [.fileSizeKey])
                bytes += Int64(v.fileSize ?? 0)
                guard bytes <= 4 * 1024 * 1024 * 1024, result.count < 100000 else { throw NativeMigrationError.unsupported }
                let basePath = home.standardizedFileURL.resolvingSymlinksInPath().path
                let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
                guard filePath.hasPrefix(basePath + "/") else { throw NativeMigrationError.invalid }
                result[String(filePath.dropFirst(basePath.count + 1))] = try hash(file)
            }
        }
        return result
    }
    /// New official versions append task-settings metadata on resume. Preserve the
    /// original history byte-for-byte and permit only that known, same-thread suffix.
    static func verifyLoadedRollout(original: URL, loaded: URL, threadID: String) throws -> String {
        try safe(original); try safe(loaded)
        let originalSize = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let loadedSize = try loaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard originalSize > 0, originalSize <= 128 * 1024 * 1024, loadedSize >= originalSize,
              loadedSize <= originalSize + 2 * 1024 * 1024 else { throw NativeMigrationError.changed }
        let before = try Data(contentsOf: original), after = try Data(contentsOf: loaded)
        guard after.starts(with: before) else { throw NativeMigrationError.changed }
        let extra = after.dropFirst(before.count)
        if !extra.isEmpty {
            guard extra.last == 10 else { throw NativeMigrationError.changed }
            let lines = extra.split(separator: 10)
            guard lines.count <= 10 else { throw NativeMigrationError.changed }
            for line in lines {
                guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      record["type"] as? String == "event_msg", let payload = record["payload"] as? [String: Any],
                      payload["type"] as? String == "thread_settings_applied", payload["thread_id"] as? String == threadID else { throw NativeMigrationError.changed }
            }
        }
        return try hash(loaded)
    }
    static func copy(_ file: URL, to dest: URL) throws {
        try safe(file); try safe(dest); try directory(dest.deletingLastPathComponent())
        try fm.copyItem(at: file, to: dest)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
    }
    static func rows(_ url: URL, _ sql: String, bindings: [String] = [], diagnosticStage: String? = nil) throws -> [[String]] {
        try safe(url)
        var db: OpaquePointer?
        func failure(_ operation: String, _ status: Int32) -> Error {
            if let diagnosticStage {
                return NativeMigrationDiagnostic(stage: diagnosticStage, code: "sqlite-\(operation)-\(status)", extendedCode: db.map { Int(sqlite3_extended_errcode($0)) }, systemCode: db.map { Int(sqlite3_system_errno($0)) }, database: ["state_5.sqlite", "goals_1.sqlite", "thread_history_1.sqlite", "logs_2.sqlite", "memories_1.sqlite", "queue_1.sqlite", "memories_v2_1.sqlite"].contains(url.lastPathComponent) ? url.lastPathComponent : "other.sqlite")
            }
            return NativeMigrationDiagnostic(stage: "database", code: "sqlite-\(operation)-\(status)", extendedCode: db.map { Int(sqlite3_extended_errcode($0)) }, systemCode: db.map { Int(sqlite3_system_errno($0)) }, database: ["state_5.sqlite", "goals_1.sqlite", "thread_history_1.sqlite", "logs_2.sqlite", "memories_1.sqlite", "queue_1.sqlite", "memories_v2_1.sqlite"].contains(url.lastPathComponent) ? url.lastPathComponent : "other.sqlite")
        }
        let opened = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard opened == SQLITE_OK, let db else {
            let error = failure("open", opened)
            if let db { sqlite3_close(db) }
            throw error
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            let error = failure("prepare", prepared)
            if let statement { sqlite3_finalize(statement) }
            throw error
        }
        defer { sqlite3_finalize(statement) }
        for (index, text) in bindings.enumerated() {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bound = sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            guard bound == SQLITE_OK else { throw failure("bind", bound) }
        }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure("step", status) }
            guard result.count < 10000 else {
                if let diagnosticStage { throw NativeMigrationDiagnostic(stage: diagnosticStage, code: "rowLimit") }
                throw NativeMigrationError.incompatible
            }
            result.append((0..<sqlite3_column_count(statement)).map { col in
                sqlite3_column_text(statement, col).map { String(cString: $0) } ?? ""
            })
        }
    }
    static func schema(_ home: URL, threadID: String, source: Bool) throws {
        let stage = source ? "sourceSchema" : "targetSchema"
        func readRows(_ url: URL, _ sql: String, bindings: [String] = []) throws -> [[String]] {
            try rows(url, sql, bindings: bindings, diagnosticStage: stage)
        }
        let db = home.appendingPathComponent("state_5.sqlite")
        let names = try fm.contentsOfDirectory(atPath: home.path)
        let versions = names.filter { ($0.hasPrefix("state_") || $0.hasPrefix("thread_history_") || $0.hasPrefix("goals_")) && $0.hasSuffix(".sqlite") }
        guard versions.allSatisfy({ ["state_5.sqlite", "thread_history_1.sqlite", "goals_1.sqlite"].contains($0) }) else { throw NativeMigrationDiagnostic(stage: stage, code: "unsupportedDatabaseVersion") }
        if !fm.fileExists(atPath: db.path) { if source { throw NativeMigrationDiagnostic(stage: stage, code: "missingStateDatabase") }; return }
        let columns = try readRows(db, "PRAGMA table_info(threads)").map { $0[1] }
        guard Set(["id", "rollout_path", "cwd"]).isSubset(of: Set(columns)) else { throw NativeMigrationDiagnostic(stage: stage, code: "missingThreadColumns") }
        let existing = try readRows(db, "SELECT id FROM threads WHERE id=?", bindings: [threadID])
        if !source { guard existing.isEmpty else { throw NativeMigrationError.conflict }; return }
        guard existing.count == 1 else { throw NativeMigrationError.invalid }
        let tables = Set(try readRows(db, "SELECT name FROM sqlite_master WHERE type='table'").map { $0[0] })
        for table in ["thread_spawn_edges", "thread_artifacts", "thread_dynamic_tools"] where tables.contains(table) {
            let cols = try readRows(db, "PRAGMA table_info(\(table))").map { $0[1] }.filter { $0 == "thread_id" || $0.hasSuffix("_thread_id") }
            guard !cols.isEmpty else { throw NativeMigrationError.incompatible }
            let predicate = cols.map { "\($0)=?" }.joined(separator: " OR ")
            guard try readRows(db, "SELECT 1 FROM \(table) WHERE \(predicate) LIMIT 1", bindings: cols.map { _ in threadID }).isEmpty else { throw NativeMigrationError.unsupported }
        }
        let goals = home.appendingPathComponent("goals_1.sqlite")
        if fm.fileExists(atPath: goals.path) {
            let tables = try readRows(goals, "SELECT name FROM sqlite_master WHERE type='table'").map { $0[0] }
            if tables.contains("thread_goals"), !(try readRows(goals, "SELECT 1 FROM thread_goals WHERE thread_id=? LIMIT 1", bindings: [threadID])).isEmpty { throw NativeMigrationError.unsupported }
        }
    }
    static func stopped(_ home: URL, electron: URL) throws {
        try safe(home)
        let lock = electron.appendingPathComponent("SingletonLock")
        if let target = try? fm.destinationOfSymbolicLink(atPath: lock.path) {
            do {
                try SingletonLockPolicy.validate(target: target, localHostname: ProcessInfo.processInfo.hostName) { pid in
                    kill(pid, 0) == 0 || errno == EPERM
                }
            } catch {
                let pid = target.split(separator: "-").last.flatMap { Int32($0) }
                throw NativeMigrationDiagnostic(stage: "occupancy", code: pid.map { "clientLock-pid-\($0)" } ?? "clientLock-unrecognized")
            }
        } else if fm.fileExists(atPath: lock.path) { throw NativeMigrationDiagnostic(stage: "occupancy", code: "clientLock-unrecognized") }
        guard fm.fileExists(atPath: home.path) else { return }
        // The app-server and SQLite handles can outlive the GUI process briefly.
        // Give normal shutdown a bounded grace period before reporting the account busy.
        let deadline = Date().addingTimeInterval(3)
        while true {
            guard let occupied = try openFile(home) else { return }
            guard Date() < deadline else { throw occupied }
            Thread.sleep(forTimeInterval: min(0.25, max(0, deadline.timeIntervalSinceNow)))
        }
    }
    /// Inspect open handles, not the presence of WAL/SHM files. Plugins and
    /// computer-use helpers can outlive Electron and do not own thread storage.
    static func isMigrationStorage(_ path: String, home: URL) -> Bool {
        isMigrationStorage(path, rootPath: home.path)
    }
    private static func isMigrationStorage(_ path: String, rootPath: String) -> Bool {
        let prefix = rootPath + "/"
        guard path.hasPrefix(prefix) else { return false }
        let relative = String(path.dropFirst(prefix.count))
        // Keep root files conservative, including future DB versions and auth/config.
        if !relative.contains("/") { return !relative.isEmpty }
        return included(relative) || relative.hasPrefix("sqlite/") || relative.hasPrefix("thread-writer-locks/")
    }

    /// Parse only regular file handles and memory mappings. A plugin's cwd or
    /// a directory descriptor cannot write task storage and must not block import.
    static func occupancy(in output: String, rootPath: String) -> NativeMigrationDiagnostic? {
        var pid: Int32?, descriptor = "", kind = ""
        for line in output.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value); descriptor = ""; kind = ""
            case "f": descriptor = value; kind = ""
            case "t": kind = value
            case "n":
                guard let pid, pid > 0, kind == "REG", descriptor != "cwd", descriptor != "rtd",
                      isMigrationStorage(value, rootPath: rootPath) else { continue }
                let relative = String(value.dropFirst(rootPath.count + 1))
                let first = String(relative.split(separator: "/").first ?? "")
                let known = ["state_5.sqlite", "thread_history_1.sqlite", "goals_1.sqlite", "logs_2.sqlite", "queue_1.sqlite", "memories_1.sqlite", "memories_v2_1.sqlite"]
                let category = known.first(where: { first == $0 || first.hasPrefix($0 + "-") }) ?? (["sessions", "archived_sessions", "sqlite", "thread-writer-locks"].contains(first) ? first : "account-file")
                return NativeMigrationDiagnostic(stage: "occupancy", code: "openFile-pid-\(pid)", database: category)
            default: break
            }
        }
        return nil
    }

    private static func openFile(_ home: URL) throws -> NativeMigrationDiagnostic? {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // +D recursively walks plugin caches, can time out, and treats helper
        // executables/cwd as account occupancy. Query handles for this user instead.
        process.arguments = ["-n", "-P", "-u", String(getuid()), "-Fpftn"]
        process.standardOutput = output; process.standardError = error
        try process.run()
        let outFD = output.fileHandleForReading.fileDescriptor, errFD = error.fileHandleForReading.fileDescriptor
        defer { try? output.fileHandleForReading.close(); try? error.fileHandleForReading.close() }
        for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var stdout = Data(), stderr = Data()
        func drain(_ fd: Int32, into data: inout Data, limit: Int) throws {
            var bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    data.append(contentsOf: bytes.prefix(count))
                    guard data.count <= limit else { throw NativeMigrationDiagnostic(stage: "occupancy", code: "outputLimit") }
                } else if count == 0 || errno == EAGAIN { return }
                else if errno != EINTR { throw NativeMigrationDiagnostic(stage: "occupancy", code: "readFailed") }
            }
        }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        let end = Date().addingTimeInterval(10)
        repeat {
            try drain(outFD, into: &stdout, limit: 32 * 1024 * 1024)
            try drain(errFD, into: &stderr, limit: 64 * 1024)
            if !process.isRunning { break }
            guard Date() < end else { throw NativeMigrationDiagnostic(stage: "occupancy", code: "timeout") }
            Thread.sleep(forTimeInterval: 0.02)
        } while true
        try drain(outFD, into: &stdout, limit: 32 * 1024 * 1024)
        try drain(errFD, into: &stderr, limit: 64 * 1024)
        guard [0, 1].contains(process.terminationStatus), stderr.isEmpty else {
            throw NativeMigrationDiagnostic(stage: "occupancy", code: "lsof-\(process.terminationStatus)")
        }
        // lsof reports kernel paths (/private/var), while Foundation's
        // standardizedFileURL can shorten an existing path to /var.
        guard let resolved = realpath(home.path, nil) else {
            throw NativeMigrationDiagnostic(stage: "occupancy", code: "pathResolution")
        }
        let canonicalHome = String(cString: resolved)
        free(resolved)
        return occupancy(in: String(decoding: stdout, as: UTF8.self), rootPath: canonicalHome)
    }
}
