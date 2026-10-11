import AppKit

// Compile the real launch adapter without UI/journal dependencies.
enum CodexMError: Error { case incompatibleRuntime, launchFailed, ambiguousInstance, invalidName }
enum AppFailure { static func capture(_ error: Error, operation: String) -> Error { error } }

@main struct DesktopLaunchTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CodexM-launch-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let runtime = RuntimeInfo(appURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/LaunchServicesProbe"), bundleID: "dev.codexm.launch-services-probe", version: "1", build: "1")
        let profiles = [Profile(id: UUID(), name: "A", createdAt: Date()), Profile(id: UUID(), name: "B", createdAt: Date())]
        var identities: [ProcessIdentity] = []
        defer { for identity in identities where ProcessProbe.matches(identity) { kill(identity.pid, SIGTERM) } }
        for profile in profiles {
            for url in [profile.codexHome(in: root), profile.electronHome(in: root)] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            let identity = try await DesktopApplicationLauncher.launch(profile: profile, root: root, runtime: runtime)
            identities.append(identity)
            let recordURL = profile.codexHome(in: root).appendingPathComponent("launch-probe.json")
            for _ in 0..<100 {
                if fm.fileExists(atPath: recordURL.path) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: Any]
            precondition(record["home"] as? String == profile.codexHome(in: root).path)
            precondition(record["electron"] as? String == profile.electronHome(in: root).path)
            precondition(record["parent"] as? Int == 1)
            precondition(record["inheritedPrivateEnvironment"] as? Bool == false)
            precondition(OpenAICodexDesktopAdapter().owns(identity, profile: profile, root: root))
            precondition(!OpenAICodexDesktopAdapter().owns(identity, profile: profiles.first { $0.id != profile.id }!, root: root))
        }
        precondition(identities[0].pid != identities[1].pid)
        kill(identities[0].pid, SIGTERM)
        for _ in 0..<100 {
            if !ProcessProbe.matches(identities[0]) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(!ProcessProbe.matches(identities[0]) && ProcessProbe.matches(identities[1]))
        print("PASS: two Launch Services app instances, launchd parent, isolated homes and arguments, private environment filtering, account ownership and independent termination")
    }
}
