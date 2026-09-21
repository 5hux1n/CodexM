import Foundation
import CryptoKit
import Darwin

/// Owns only the explicitly spawned helper. No shell, inherited account environment,
/// model requests, or accepted server-side tool/permission requests.
final class NativeChild {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var sequence = 0
    init(binary: URL, arguments: [String], home: URL, cwd: URL) throws {
        process.executableURL = binary; process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = Self.environment(home: home)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    static func environment(home: URL) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var result = parent.filter { ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME"].contains($0.key) }
        result["CODEX_HOME"] = home.path
        return result
    }
    deinit { close() }
    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let end = Date().addingTimeInterval(3)
            while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }
    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    private func readLine(deadline: Date) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline); return line
            }
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { throw NativeMigrationError.helper }
            else if errno != EAGAIN && errno != EINTR { throw NativeMigrationError.helper }
            if buffer.count > 64 * 1024 * 1024 { throw NativeMigrationError.helper }
            if count < 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        throw NativeMigrationError.helper
    }
    func version() throws -> String {
        String(decoding: try readLine(deadline: Date().addingTimeInterval(10)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        guard ["initialize", "thread/resume", "thread/read", "thread/turns/list"].contains(method) else { throw NativeMigrationError.helper }
        sequence += 1; let id = sequence
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let data = try readLine(deadline: deadline)
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if response["method"] != nil, let requestID = response["id"] {
                try send(["id": requestID, "error": ["code": -32601, "message": "Migration client does not execute tools or authorize actions"]])
                continue
            }
            if response["id"] as? Int == id {
                if let error = response["error"] as? [String: Any] {
                    let stage = ["initialize": "initialize", "thread/resume": "resume", "thread/read": "read", "thread/turns/list": "page"][method] ?? "load"
                    throw NativeMigrationDiagnostic(stage: stage, code: "RPC \((error["code"] as? Int) ?? -1)")
                }
                guard let result = response["result"] as? [String: Any] else { throw NativeMigrationError.helper }
                return result
            }
        }
        throw NativeMigrationError.helper
    }
    func initialize() throws {
        _ = try call("initialize", ["clientInfo": ["name": "codexm-native-migration", "version": "1.0"], "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized", "params": [:]])
    }
}

enum NativeHistoryLoader {
    static let fixtureCLI = "codex-cli 0.154.0-alpha.6.2"
    static func version(binary: URL, home: URL) throws -> String {
        let child = try NativeChild(binary: binary, arguments: ["--version"], home: home, cwd: home)
        defer { child.close() }
        let value = try child.version()
        guard value.hasPrefix("codex-cli "), value.count < 160 else { throw NativeMigrationError.runtime }
        return value
    }
    /// Test the selected rollout with the current helper in a fresh credential-free home.
    /// A changed version number alone neither grants compatibility nor rejects old history.
    static func probe(binary: URL, rollout: URL, project: String, threadID: String, expectedHash: String) throws -> NativeEvidence {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("CodexM-Compatibility-\(UUID())").standardizedFileURL
        try NativeFiles.directory(home)
        defer { try? FileManager.default.removeItem(at: home) }
        let copy = home.appendingPathComponent("sessions/codexm-import").appendingPathComponent(rollout.lastPathComponent)
        try NativeFiles.copy(rollout, to: copy)
        guard try NativeFiles.hash(copy) == expectedHash else { throw NativeMigrationError.changed }
        var stage = "load"
        do {
            let first = try load(binary: binary, home: home, project: project, threadID: threadID, hydrate: true)
            stage = "restart"
            let second = try load(binary: binary, home: home, project: project, threadID: threadID, hydrate: false)
            stage = "compare"
            guard first == second else { throw NativeMigrationError.capability }
            stage = "rollout"
            _ = try NativeFiles.verifyLoadedRollout(original: rollout, loaded: copy, threadID: threadID)
            // The loader must not create un-backed-up data formats before we use it on a target.
            stage = "schema"
            try NativeFiles.schema(home, threadID: threadID, source: true)
            return second
        } catch let detail as NativeMigrationDiagnostic { throw detail }
          catch { throw NativeMigrationDiagnostic(stage: stage, code: (error as? NativeMigrationError)?.rawValue ?? "localIO") }
    }
    static func load(binary: URL, home: URL, project: String, threadID: String, hydrate: Bool) throws -> NativeEvidence {
        let child = try NativeChild(binary: binary, arguments: ["app-server", "--stdio", "-c", "analytics.enabled=false", "-c", "mcp_servers={}", "-c", "cli_auth_credentials_store=\"file\""], home: home, cwd: home)
        defer { child.close() }
        try child.initialize()
        if hydrate {
            // These profiles use the official ChatGPT account runtime. Historical custom
            // provider names must not require copying the source's config or credentials.
            // This only reconstructs local history; it never starts a model turn.
            _ = try child.call("thread/resume", ["threadId": threadID, "excludeTurns": true, "modelProvider": "openai", "approvalPolicy": "never", "sandbox": "read-only"])
        }
        let result = try child.call("thread/read", ["threadId": threadID, "includeTurns": false])
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == threadID else { throw NativeMigrationError.helper }
        var cursor: String?
        var totalTurns = 0, totalItems = 0
        var seen: Set<String> = []
        var hasher = SHA256()
        for _ in 0..<1000 {
            var params: [String: Any] = ["threadId": threadID, "limit": 25, "itemsView": "full", "sortDirection": "asc"]
            if let cursor { params["cursor"] = cursor }
            let page = try child.call("thread/turns/list", params)
            guard let turns = page["data"] as? [[String: Any]] else { throw NativeMigrationError.helper }
            totalTurns += turns.count
            for turn in turns {
                guard let items = turn["items"] as? [[String: Any]] else { throw NativeMigrationError.helper }
                totalItems += items.count
                hasher.update(data: try JSONSerialization.data(withJSONObject: turn, options: [.sortedKeys]))
            }
            cursor = page["nextCursor"] as? String
            if cursor == nil {
                guard totalTurns > 0, totalItems > 0 else { throw NativeMigrationError.helper }
                return NativeEvidence(turns: totalTurns, items: totalItems, historyHash: hasher.finalize().map { String(format: "%02x", $0) }.joined())
            }
            guard seen.insert(cursor!).inserted else { throw NativeMigrationError.helper }
        }
        throw NativeMigrationError.helper
    }
}
