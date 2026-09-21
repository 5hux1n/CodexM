import AppKit

protocol CodexRuntimeAdapter: Sendable {
    func inspect(appURL: URL) throws -> RuntimeInfo
    func owns(_ identity: ProcessIdentity, profile: Profile, root: URL) -> Bool
    func launch(profile: Profile, root: URL, runtime: RuntimeInfo, onExit: @escaping @Sendable (Int32, Int32, Bool) -> Void) throws -> (Process, ProcessIdentity)
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
        guard appURL.pathExtension == "app", let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.openai.codex",
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw CodexMError.incompatibleRuntime }
        let executable = appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        guard executable.resolvingSymlinksInPath().path.hasPrefix(appURL.resolvingSymlinksInPath().path + "/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodexMError.incompatibleRuntime }
        return RuntimeInfo(appURL: appURL, executableURL: executable, bundleID: "com.openai.codex", version: info["CFBundleShortVersionString"] as? String ?? "?", build: info["CFBundleVersion"] as? String ?? "?")
    }

    func launch(profile: Profile, root: URL, runtime: RuntimeInfo, onExit: @escaping @Sendable (Int32, Int32, Bool) -> Void) throws -> (Process, ProcessIdentity) {
        let process = Process()
        process.executableURL = runtime.executableURL
        process.environment = Self.environment(profile: profile, root: root, parent: ProcessInfo.processInfo.environment)
        process.arguments = ["--user-data-dir=\(profile.electronHome(in: root).path)"]
        process.currentDirectoryURL = profile.root(in: root)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { child in onExit(child.processIdentifier, child.terminationStatus, child.terminationReason == .uncaughtSignal) }
        do { try process.run() } catch { throw CodexMError.launchFailed }
        guard let identity = ProcessProbe.identity(pid: process.processIdentifier) else { throw CodexMError.launchFailed }
        return (process, identity)
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

struct ProcessExit: Sendable { let status: Int32; let signaled: Bool }

actor RuntimeService {
    private let adapter: any CodexRuntimeAdapter
    private var processes: [Int32: Process] = [:]
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
    func exitOutcome(pid: Int32) -> ProcessExit? {
        guard let process = processes[pid], !process.isRunning else { return nil }
        return ProcessExit(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal)
    }
    func matches(_ identity: ProcessIdentity) -> Bool { ProcessProbe.matches(identity) }
    func launch(_ profile: Profile, root: URL, runtime: RuntimeInfo, onExit: @escaping @Sendable (Int32, Int32, Bool) -> Void) throws -> ProcessIdentity {
        _ = try adapter.inspect(appURL: runtime.appURL)
        let (process, identity) = try adapter.launch(profile: profile, root: root, runtime: runtime, onExit: onExit)
        processes[identity.pid] = process
        return identity
    }
    func terminate(_ identity: ProcessIdentity, profile: Profile, root: URL, force: Bool) -> Bool {
        guard identity.pid > 0, adapter.owns(identity, profile: profile, root: root), ProcessProbe.matches(identity) else { return false }
        return kill(identity.pid, force ? SIGKILL : SIGTERM) == 0
    }
    func release(pid: Int32) { processes.removeValue(forKey: pid) }
}
