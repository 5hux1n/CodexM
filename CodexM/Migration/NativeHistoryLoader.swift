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
    private var stage = "initialize"
    init(binary: URL, arguments: [String], home: URL, cwd: URL) throws {
        process.executableURL = binary; process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = Self.environment(home: home)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch {
            throw NativeMigrationDiagnostic(stage: "initialize", code: "launch-\((error as NSError).code)")
        }
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
            else if count == 0 { throw NativeMigrationDiagnostic(stage: stage, code: "transport-eof") }
            else if errno != EAGAIN && errno != EINTR { throw NativeMigrationDiagnostic(stage: stage, code: "transport-read", systemCode: Int(errno)) }
            if buffer.count > 64 * 1024 * 1024 { throw NativeMigrationDiagnostic(stage: stage, code: "transport-outputLimit") }
            if count < 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        throw NativeMigrationDiagnostic(stage: stage, code: "transport-timeout")
    }
    func version() throws -> String {
        String(decoding: try readLine(deadline: Date().addingTimeInterval(10)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        guard ["initialize", "thread/resume", "thread/read", "thread/turns/list", "project/list", "project/create", "thread/metadata/update"].contains(method) else { throw NativeMigrationError.helper }
        stage = ["initialize": "initialize", "thread/resume": "resume", "thread/read": "read", "thread/turns/list": "page", "project/list": "project", "project/create": "project", "thread/metadata/update": "project"][method] ?? "load"
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
                    let stage = ["initialize": "initialize", "thread/resume": "resume", "thread/read": "read", "thread/turns/list": "page", "project/list": "project", "project/create": "project", "thread/metadata/update": "project"][method] ?? "load"
                    throw NativeMigrationDiagnostic(stage: stage, code: "RPC \((error["code"] as? Int) ?? -1)")
                }
                guard let result = response["result"] as? [String: Any] else { throw NativeMigrationDiagnostic(stage: stage, code: "rpc-missingResult") }
                return result
            }
        }
        throw NativeMigrationDiagnostic(stage: stage, code: "rpc-timeout")
    }
    func initialize() throws {
        _ = try call("initialize", ["clientInfo": ["name": "codexm-native-migration", "version": "1.0"], "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized", "params": [:]])
    }
}

enum NativeHistoryLoader {
    static func sourceProject(home: URL, threadID: String, cwd: String) throws -> NativeProject? {
        let db = home.appendingPathComponent("state_5.sqlite")
        let columns = try NativeFiles.rows(db, "PRAGMA table_info(threads)").map { $0[1] }
        if columns.contains("project_id"), let id = try NativeFiles.rows(db, "SELECT project_id FROM threads WHERE id=?", bindings: [threadID]).first?.first, !id.isEmpty {
            let names = try NativeFiles.rows(db, "SELECT name FROM projects WHERE id=?", bindings: [id])
            let roots = try NativeFiles.rows(db, "SELECT path FROM project_roots WHERE project_id=? ORDER BY position", bindings: [id]).map { $0[0] }
            guard let name = names.first?.first, !roots.isEmpty else { throw NativeMigrationDiagnostic(stage: "project", code: "missingSourceProject") }
            return NativeProject(name: name, roots: roots)
        }
        // Older desktop versions keep assignments in global state until their
        // app-server migration completes. Read only the selected local project.
        let state = home.appendingPathComponent(".codex-global-state.json")
        guard NativeFiles.fm.fileExists(atPath: state.path) else { return nil }
        try NativeFiles.safe(state)
        guard (try state.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 16 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any] else { throw NativeMigrationDiagnostic(stage: "project", code: "invalidSourceProjectState") }
        if (value["projectless-thread-ids"] as? [String])?.contains(threadID) == true { return nil }
        let projects = value["local-projects"] as? [String: [String: Any]] ?? [:]
        let assignment = (value["thread-project-assignments"] as? [String: [String: Any]])?[threadID]
        let selected: [String: Any]?
        if let assignment {
            guard assignment["projectKind"] as? String == "local", let id = assignment["projectId"] as? String,
                  let project = projects[id] else { throw NativeMigrationDiagnostic(stage: "project", code: "unsupportedSourceProject") }
            selected = project
        } else {
            selected = projects.values.first { ($0["rootPaths"] as? [String])?.contains(cwd) == true }
        }
        guard let selected else { return nil }
        guard let name = selected["name"] as? String, let roots = selected["rootPaths"] as? [String], !roots.isEmpty,
              roots.allSatisfy({ $0.hasPrefix("/") && !$0.hasPrefix(home.path + "/") }) else { throw NativeMigrationDiagnostic(stage: "project", code: "unsupportedSourceProject") }
        return NativeProject(name: name, roots: roots)
    }

    static func assignProject(binary: URL, home: URL, threadID: String, project: NativeProject, migrationID: UUID) throws -> (id: String, name: String) {
        let child = try NativeChild(binary: binary, arguments: ["app-server", "--stdio", "-c", "analytics.enabled=false", "-c", "mcp_servers={}", "-c", "cli_auth_credentials_store=\"file\""], home: home, cwd: home)
        defer { child.close() }
        try child.initialize()
        var cursor: String?, seen: Set<String> = [], found: String?, foundName: String?
        for _ in 0..<1000 {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try child.call("project/list", params)
            guard let projects = result["data"] as? [[String: Any]] else { throw NativeMigrationDiagnostic(stage: "project", code: "invalidProjectList") }
            let matching = projects.filter { item in
                guard let roots = item["roots"] as? [[String: Any]] else { return false }
                return Set(roots.compactMap { $0["path"] as? String }) == Set(project.roots)
            }
            if let id = matching.first?["id"] as? String { found = id; foundName = matching.first?["name"] as? String; break }
            cursor = result["nextCursor"] as? String
            if cursor == nil { break }
            guard seen.insert(cursor!).inserted else { throw NativeMigrationDiagnostic(stage: "project", code: "repeatedProjectCursor") }
        }
        if found == nil {
            guard cursor == nil else { throw NativeMigrationDiagnostic(stage: "project", code: "projectPageLimit") }
            let result = try child.call("project/create", ["name": project.name, "roots": project.roots.map { ["path": $0] }, "idempotencyKey": "codexm-" + migrationID.uuidString])
            found = (result["project"] as? [String: Any])?["id"] as? String
            foundName = (result["project"] as? [String: Any])?["name"] as? String
        }
        guard let id = found else { throw NativeMigrationDiagnostic(stage: "project", code: "missingTargetProject") }
        _ = try child.call("thread/metadata/update", ["threadId": threadID, "projectId": id])
        let result = try child.call("thread/read", ["threadId": threadID, "includeTurns": false])
        guard (result["thread"] as? [String: Any])?["projectId"] as? String == id else { throw NativeMigrationDiagnostic(stage: "project", code: "projectAssignmentMismatch") }
        return (id, foundName ?? project.name)
    }
    static let fixtureCLI = "codex-cli 0.154.0-alpha.6.2"
    /// Discover the selected client's embedded CLI by bundle identity and executable
    /// metadata, so relocating or renaming the helper does not break migration.
    /// Older clients shipped a bare executable instead of a CLI app bundle.
    static func binary(in app: URL) throws -> URL {
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        func executable(_ url: URL) -> URL? {
            let candidate = url.resolvingSymlinksInPath().standardizedFileURL
            guard candidate.path.hasPrefix(root.path + "/") else { return nil }
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true, FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            return nil
        }
        let resources = root.appendingPathComponent("Contents/Resources")
        var helpers: Set<URL> = []
        if resources.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
           let entries = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            var count = 0
            while let bundle = entries.nextObject() as? URL {
                count += 1
                guard count <= 4096 else { throw NativeMigrationError.runtime }
                if entries.level > 6 { entries.skipDescendants(); continue }
                if (try? bundle.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { entries.skipDescendants(); continue }
                guard bundle.pathExtension == "app" else { continue }
                let plist = bundle.appendingPathComponent("Contents/Info.plist").resolvingSymlinksInPath()
                guard plist.path.hasPrefix(root.path + "/"),
                      let size = try? plist.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
                      let data = try? Data(contentsOf: plist),
                      let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      info["CFBundleIdentifier"] as? String == "com.openai.codex.cli",
                      let name = info["CFBundleExecutable"] as? String,
                      !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                      let helper = executable(bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)) else { continue }
                helpers.insert(helper)
            }
        }
        guard helpers.count <= 1 else { throw NativeMigrationError.runtime }
        if let helper = helpers.first { return helper }
        if let legacy = executable(resources.appendingPathComponent("codex")) { return legacy }
        throw NativeMigrationError.runtime
    }
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
          catch { throw AppFailure.capture(error, operation: "native." + stage) }
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
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == threadID else { throw NativeMigrationDiagnostic(stage: "read", code: "threadIdentityMismatch") }
        var cursor: String?
        var totalTurns = 0, totalItems = 0
        var seen: Set<String> = []
        var hasher = SHA256()
        for _ in 0..<1000 {
            var params: [String: Any] = ["threadId": threadID, "limit": 25, "itemsView": "full", "sortDirection": "asc"]
            if let cursor { params["cursor"] = cursor }
            let page = try child.call("thread/turns/list", params)
            guard let turns = page["data"] as? [[String: Any]] else { throw NativeMigrationDiagnostic(stage: "page", code: "missingTurns") }
            totalTurns += turns.count
            for turn in turns {
                guard let items = turn["items"] as? [[String: Any]] else { throw NativeMigrationDiagnostic(stage: "page", code: "missingItems") }
                totalItems += items.count
                hasher.update(data: try JSONSerialization.data(withJSONObject: turn, options: [.sortedKeys]))
            }
            cursor = page["nextCursor"] as? String
            if cursor == nil {
                guard totalTurns > 0, totalItems > 0 else { throw NativeMigrationDiagnostic(stage: "page", code: "emptyHistory") }
                return NativeEvidence(turns: totalTurns, items: totalItems, historyHash: hasher.finalize().map { String(format: "%02x", $0) }.joined())
            }
            guard seen.insert(cursor!).inserted else { throw NativeMigrationDiagnostic(stage: "page", code: "repeatedCursor") }
        }
        throw NativeMigrationDiagnostic(stage: "page", code: "pageLimit")
    }
}
