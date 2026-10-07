import Foundation
import Darwin

// Minimal error adapter for compiling the real store without the app UI/journal.
enum CodexMError: Error {
    case unsafePath, storageLocked, corruptStorage, defaultAccountProtected, profileBusy, directoryNotEmpty, invalidName, filesystemError
}
enum AppFailure {
    static func capture(_ error: Error, operation: String) -> Error { error }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double?] = []
    func append(_ value: Double?) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [Double?] { lock.lock(); defer { lock.unlock() }; return values }
}

@main struct ProfileRelocationTests {
    static func blocked(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected occupancy rejection") }
        catch CodexMError.profileBusy { }
        catch { fatalError("Unexpected error: \(error)") }
    }
    static func main() async throws {
        try SingletonLockPolicy.validate(target: "OLD-host-999", localHostname: "new-host", localVolume: true) { _ in false }
        try SingletonLockPolicy.validate(target: "MINI.local-999", localHostname: "mini.local") { _ in false }
        blocked { try SingletonLockPolicy.validate(target: "old-host-999", localHostname: "new-host") { _ in false } }
        blocked { try SingletonLockPolicy.validate(target: "old-host-999", localHostname: "new-host", localVolume: true) { _ in true } }
        for target in ["broken", "-999", "host-0", "host-noPID"] {
            blocked { try SingletonLockPolicy.validate(target: target, localHostname: "new-host", localVolume: true) { _ in false } }
        }
        let fm = FileManager.default
        if CommandLine.arguments.contains("--check-current-locks") {
            // Read metadata and lock links only; no lease, save, launch or migration.
            let actualRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexM")
            let actualState = try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: actualRoot.appendingPathComponent("profiles.json")))
            let actualStore = ProfileStore(root: actualRoot)
            for actualProfile in actualState.profiles where !actualProfile.isInstalledDefault {
                try await actualStore.assertNotLocked(actualProfile)
            }
            print("PASS: read-only current account lock checks (\(actualState.profiles.filter { !$0.isInstalledDefault }.count) profiles)")
        }
        let sandbox = fm.temporaryDirectory.appendingPathComponent("CodexM-relocation-\(UUID())")
        defer { try? fm.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("manager")
        let destination = sandbox.appendingPathComponent("moved")
        let store = ProfileStore(root: root)
        _ = try await store.load()
        let profile = Profile(id: UUID(), name: "Fixture", createdAt: Date())
        try await store.prepare(profile)
        let fixture = profile.codexHome(in: root).appendingPathComponent("fixture.txt")
        try Data("fixture-data".utf8).write(to: fixture)
        // Get a definitely exited PID rather than assuming a large PID is absent.
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        let lock = profile.electronHome(in: root).appendingPathComponent("SingletonLock")
        let stale = "old-machine.local-\(child.processIdentifier)"
        try fm.createSymbolicLink(atPath: lock.path, withDestinationPath: stale)
        let largeFile = profile.codexHome(in: root).appendingPathComponent("large.bin")
        try Data(repeating: 0x5a, count: 16 * 1024 * 1024).write(to: largeFile)
        let progress = ProgressRecorder()
        var state = StoredState(); state.profiles = [profile, .installedDefault(name: "Default")]
        try await store.save(state)
        let moved = try await store.relocateAccounts(to: destination, saving: state) { progress.append($0) }
        let samples = progress.snapshot()
        let fractions = samples.compactMap { $0 }
        precondition(samples.first! == nil && fractions.last == 1)
        precondition(fractions.contains { $0 > 0 && $0 < 1 })
        precondition(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        let relocated = moved.profiles[0]
        let movedLarge = try Data(contentsOf: relocated.codexHome(in: root).appendingPathComponent("large.bin"))
        precondition(movedLarge == Data(repeating: 0x5a, count: 16 * 1024 * 1024))
        let copiedData = try Data(contentsOf: relocated.codexHome(in: root).appendingPathComponent("fixture.txt"))
        precondition(copiedData == Data("fixture-data".utf8))
        precondition(fm.fileExists(atPath: fixture.path))
        let oldLock = try fm.destinationOfSymbolicLink(atPath: lock.path)
        let newLock = relocated.electronHome(in: root).appendingPathComponent("SingletonLock")
        precondition(oldLock == stale)
        precondition((try? fm.destinationOfSymbolicLink(atPath: newLock.path)) == nil)
        precondition(!fm.fileExists(atPath: newLock.path))
        precondition(moved.profiles[1] == state.profiles[1])
        precondition(moved.preferences.accountDataDirectory == destination.path)
        let relocatedLock = relocated.electronHome(in: root).appendingPathComponent("SingletonLock")
        try fm.createSymbolicLink(atPath: relocatedLock.path, withDestinationPath: "old-machine.local-\(getpid())")
        do {
            _ = try await store.relocateAccounts(to: sandbox.appendingPathComponent("blocked"), saving: moved)
            fatalError("Moved a live-locked profile")
        } catch CodexMError.profileBusy { }
        precondition(!fm.fileExists(atPath: sandbox.appendingPathComponent("blocked").path))
        print("PASS: byte progress preparation/intermediate/completion and monotonicity")
        print("PASS: stale renamed-host locks, remote/unknown host rejection, live PID rejection, fixture relocation, retained backup/original lock and fresh destination IPC and protected default account")
    }
}
