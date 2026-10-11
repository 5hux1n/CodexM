import AppKit

// Native fixture app: records only launch configuration, never requests access.
@main struct LaunchServicesProbe {
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["CODEX_HOME"] else { exit(2) }
        let record: [String: Any] = [
            "home": home,
            "electron": environment["CODEX_ELECTRON_USER_DATA_PATH"] ?? "",
            "arguments": CommandLine.arguments,
            "parent": getppid(),
            "pid": getpid(),
            "inheritedPrivateEnvironment": ["CODEX_APP_TOOLS_PIPE_PATH", "OPENAI_API_KEY", "CODEX_API_KEY"].contains { environment[$0] != nil }
        ]
        try JSONSerialization.data(withJSONObject: record).write(to: URL(fileURLWithPath: home).appendingPathComponent("launch-probe.json"), options: .atomic)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }
}
