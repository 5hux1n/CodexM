import AppKit

protocol CodexRuntimeAdapter: Sendable {
    func inspect(appURL: URL) throws -> RuntimeInfo
    func owns(_ identity: ProcessIdentity, profile: Profile, root: URL) -> Bool
    func launch(profile: Profile, root: URL, runtime: RuntimeInfo) async throws -> ProcessIdentity
}

struct OpenAICodexDesktopAdapter: CodexRuntimeAdapter {
    func owns(_ identity: ProcessIdentity, profile: Profile, root: URL) -> Bool {
        guard identity.pid > 0, ProcessProbe.matches(identity), let arguments = ProcessProbe.arguments(pid: identity.pid) else { return false }
        if let directory = ProcessProbe.userDataDirectory(in: arguments) {
            return URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath() == profile.electronHome(in: root).standardizedFileURL.resolvingSymlinksInPath()
        }
        // A default instance started outside CodexM has no --user-data-dir argument.
        guard profile.isInstalledDefault,
              let lock = try? FileManager.default.destinationOfSymbolicLink(atPath: profile.electronHome(in: root).appendingPathComponent("SingletonLock").path),
              let part = lock.split(separator: "-").last, Int32(part) == identity.pid else { return false }
        return true
    }

    func inspect(appURL: URL) throws -> RuntimeInfo {
        // Read the plist afresh: Bundle caches can hide an in-place app update.
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard appURL.pathExtension == "app" else { throw CodexMError.incompatibleRuntime }
        let data: Data
        do { data = try Data(contentsOf: plistURL) }
        catch { throw AppFailure.capture(error, operation: "runtime.inspect") }
        guard
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.openai.codex",
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw CodexMError.incompatibleRuntime }
        let executable = appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        guard executable.resolvingSymlinksInPath().path.hasPrefix(appURL.resolvingSymlinksInPath().path + "/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodexMError.incompatibleRuntime }
        return RuntimeInfo(appURL: appURL, executableURL: executable, bundleID: "com.openai.codex", version: info["CFBundleShortVersionString"] as? String ?? "?", build: info["CFBundleVersion"] as? String ?? "?")
    }

    func launch(profile: Profile, root: URL, runtime: RuntimeInfo) async throws -> ProcessIdentity {
        let identity = try await DesktopApplicationLauncher.launch(profile: profile, root: root, runtime: runtime)
        guard owns(identity, profile: profile, root: root) else { throw CodexMError.ambiguousInstance }
        return identity
    }

    static func environment(profile: Profile, root: URL, parent: [String: String]) -> [String: String] {
        // Launching the imported task must use the target account's own identity.
        // A manager started inside a source Codex terminal may inherit API keys,
        // provider overrides and per-account IPC; only ordinary OS values survive.
        let allowed: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME", "SHELL", "TZ", "__CF_USER_TEXT_ENCODING"]
        var environment = parent.filter { allowed.contains($0.key) }
        environment["CODEX_HOME"] = profile.codexHome(in: root).path
        environment["CODEX_ELECTRON_USER_DATA_PATH"] = profile.electronHome(in: root).path
        // CodexM may itself have been opened from a Codex terminal. An inherited
        // per-instance IPC endpoint must not be transplanted into a new instance.
        environment.removeValue(forKey: "CODEX_APP_TOOLS_PIPE_PATH")
        return environment
    }
}

/// Launch Services starts the official app as an application rather than as
/// CodexM's child process, so privacy requests can use the client's identity.
enum DesktopApplicationLauncher {
    static func launch(profile: Profile, root: URL, runtime: RuntimeInfo) async throws -> ProcessIdentity {
        let executable = runtime.executableURL.resolvingSymlinksInPath().path
        let existing = Set(ProcessProbe.allIdentities(executables: [executable]))
        // NSWorkspace's environment is additive and can inherit the caller's
        // account IPC/credentials. A clean /usr/bin/open bridge uses the same
        // Launch Services path without propagating the manager's environment.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-n", "-a", runtime.appURL.path, "--args", "--user-data-dir=\(profile.electronHome(in: root).path)"]
        launcher.environment = OpenAICodexDesktopAdapter.environment(profile: profile, root: root, parent: ProcessInfo.processInfo.environment)
        launcher.currentDirectoryURL = profile.root(in: root)
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            launcher.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
            do { try launcher.run() }
            catch { continuation.resume(throwing: AppFailure.capture(error, operation: "account.launch")) }
        }
        guard status == 0 else { throw CodexMError.launchFailed }
        for _ in 0..<200 {
            let candidates = ProcessProbe.allIdentities(executables: [executable]).filter {
                !existing.contains($0) && OpenAICodexDesktopAdapter().owns($0, profile: profile, root: root)
            }
            guard candidates.count <= 1 else { throw CodexMError.ambiguousInstance }
            if let identity = candidates.first { return identity }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CodexMError.launchFailed
    }
}

actor RuntimeService {
    private let adapter: any CodexRuntimeAdapter
    init(adapter: any CodexRuntimeAdapter = OpenAICodexDesktopAdapter()) { self.adapter = adapter }

    func detect(preferred: String?, discovered: URL?) -> RuntimeInfo? {
        let candidates = [preferred.map { URL(fileURLWithPath: $0) }, URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app"), discovered].compactMap { $0 }
        return candidates.lazy.compactMap { try? self.adapter.inspect(appURL: $0) }.first
    }
    func inspect(_ url: URL) throws -> RuntimeInfo { try adapter.inspect(appURL: url) }
    func scan(executables: Set<String>) -> [ProcessIdentity] { ProcessProbe.allIdentities(executables: executables) }
    func installedDefaultIdentity(profile: Profile, root: URL, runtime: RuntimeInfo) -> ProcessIdentity? {
        guard profile.isInstalledDefault else { return nil }
        let lock = profile.electronHome(in: root).appendingPathComponent("SingletonLock")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path),
              let component = target.split(separator: "-").last, let pid = Int32(component),
              let identity = ProcessProbe.identity(pid: pid),
              URL(fileURLWithPath: identity.executable).resolvingSymlinksInPath() == runtime.executableURL.resolvingSymlinksInPath(),
              let arguments = ProcessProbe.arguments(pid: pid) else { return nil }
        if let directory = ProcessProbe.userDataDirectory(in: arguments),
           URL(fileURLWithPath: directory).standardizedFileURL != profile.electronHome(in: root).standardizedFileURL { return nil }
        return identity
    }
    func arguments(pid: Int32) -> [String]? { ProcessProbe.arguments(pid: pid) }
    func currentIdentity(pid: Int32) -> ProcessIdentity? { ProcessProbe.identity(pid: pid) }
    func matches(_ identity: ProcessIdentity) -> Bool { ProcessProbe.matches(identity) }
    func launch(_ profile: Profile, root: URL, runtime: RuntimeInfo) async throws -> ProcessIdentity {
        _ = try adapter.inspect(appURL: runtime.appURL)
        return try await adapter.launch(profile: profile, root: root, runtime: runtime)
    }
    func terminate(_ identity: ProcessIdentity, profile: Profile, root: URL, force: Bool) -> Bool {
        guard identity.pid > 0, adapter.owns(identity, profile: profile, root: root), ProcessProbe.matches(identity) else { return false }
        return kill(identity.pid, force ? SIGKILL : SIGTERM) == 0
    }
}
