import Foundation

// Small adapters isolate the real storage, coordinator and official loader
// from UI/localization. No loader or projection behavior is mocked.
enum CodexMError: String, Error { case unsafePath, handoffTranscript, handoffProject, corruptStorage, defaultAccountProtected, directoryNotEmpty, filesystemError, profileBusy, storageLocked, invalidName }
enum L10n { static func text(_ key: String) -> String { key } }
struct AppFailure: Error, LocalizedError, Codable, Sendable {
    var code: String
    var impactKey: String?
    var runtimeVersion: String?
    var errorDescription: String? { code }
    static func capture(_ error: Error, operation: String) -> AppFailure {
        if let failure = error as? AppFailure { return failure }
        return AppFailure(code: (error as? NativeMigrationError)?.rawValue ?? (error as? NativeMigrationDiagnostic)?.code ?? String(describing: error))
    }
}
enum DiagnosticJournal { static func record(_ failure: AppFailure) {} }

@main struct NativeRoundTripTests {
    static func appendTurn(_ file: URL, number: Int) throws {
        let turn = UUID().uuidString.lowercased()
        let time = "2026-10-12T10:00:0\(number).000Z"
        let records: [[String: Any]] = [
            ["timestamp": time, "type": "event_msg", "payload": ["type": "task_started", "turn_id": turn, "model_context_window": 200000]],
            ["timestamp": time, "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fixture request \(number)"]]]],
            ["timestamp": time, "type": "event_msg", "payload": ["type": "user_message", "message": "Fixture request \(number)", "images": [], "local_images": []]],
            ["timestamp": time, "type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Fixture response \(number)"]]]],
            ["timestamp": time, "type": "event_msg", "payload": ["type": "agent_message", "message": "Fixture response \(number)"]],
            ["timestamp": time, "type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn, "last_agent_message": "Fixture response \(number)"]]
        ]
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd()
        for record in records { var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]); data.append(10); try handle.write(contentsOf: data) }
    }
    static func main() async throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CodexM-roundtrip-\(UUID())").resolvingSymlinksInPath()
        try NativeFiles.directory(root)
        // Retain synthetic fixtures on failure for protocol diagnostics.
        let project = root.appendingPathComponent("project"); try NativeFiles.directory(project)
        let a = Profile(id: UUID(), name: "A", createdAt: Date()), b = Profile(id: UUID(), name: "B", createdAt: Date())
        for profile in [a,b] { try NativeFiles.directory(profile.codexHome(in: root)); try NativeFiles.directory(profile.electronHome(in: root)) }
        let tid = UUID().uuidString.lowercased()
        let original = a.codexHome(in: root).appendingPathComponent("sessions/2026/10/12/rollout-2026-10-12T10-00-00-\(tid).jsonl")
        try NativeFiles.directory(original.deletingLastPathComponent())
        let meta: [String: Any] = ["timestamp": "2026-10-12T10:00:00.000Z", "type": "session_meta", "payload": ["id": tid, "session_id": UUID().uuidString.lowercased(), "originator": "codex_cli_rs", "base_instructions": ["text": "Fixture instructions"], "timestamp": "2026-10-12T10:00:00.000Z", "cwd": project.path, "cli_version": "0.154.0-alpha.6.2", "source": "cli", "model_provider": "openai", "history_mode": "legacy"]]
        var data = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]); data.append(10); try data.write(to: original)
        try appendTurn(original, number: 1)
        let one = try NativeHistoryLoader.load(binary: binary, home: a.codexHome(in: root), project: project.path, threadID: tid, hydrate: true)
        precondition(one.turns == 1)
        func thread(_ profile: Profile, file: URL) -> ThreadMetadata { ThreadMetadata(profileID: profile.id, threadID: tid, title: "Fixture", cwd: project.path, rolloutPath: file.path, updatedAt: Date(), archived: false) }
        let legacyPath = root.appendingPathComponent("legacy-codex/sessions/2026/10/12/" + original.lastPathComponent)
        try NativeFiles.directory(legacyPath.deletingLastPathComponent())
        try fm.createSymbolicLink(at: legacyPath, withDestinationURL: original)
        let resolved = try RolloutSource.resolve(thread: thread(a, file: legacyPath), home: a.codexHome(in: root))
        precondition(resolved.resolvingSymlinksInPath() == original.resolvingSymlinksInPath())
        let coordinator = NativeMigrationCoordinator()
        let first = try await coordinator.migrate(thread: thread(a, file: original), source: a, target: b, root: root, binary: binary)
        guard first.status == "verified" else { fatalError("Initial import: \(first.failure?.code ?? first.failureCode ?? first.status)") }
        let received = b.codexHome(in: root).appendingPathComponent(first.rolloutRelative)
        try appendTurn(received, number: 2)
        let two = try NativeHistoryLoader.load(binary: binary, home: b.codexHome(in: root), project: project.path, threadID: tid, hydrate: true)
        precondition(two.turns == 2)
        let returned = try await coordinator.migrate(thread: thread(b, file: received), source: b, target: a, root: root, binary: binary)
        guard returned.status == "verified" else { fatalError("Return: \(returned.failure?.code ?? returned.failureCode ?? returned.status)") }
        precondition(returned.transferKind == "return" && returned.evidence == two)
        let restarted = try NativeHistoryLoader.load(binary: binary, home: a.codexHome(in: root), project: project.path, threadID: tid, hydrate: false)
        precondition(restarted == two)
        let beforeRetry = try NativeFiles.inventory(a.codexHome(in: root))
        let retry = try await coordinator.migrate(thread: thread(b, file: received), source: b, target: a, root: root, binary: binary)
        precondition(retry.id == returned.id)
        let afterRetry = try NativeFiles.inventory(a.codexHome(in: root)); precondition(afterRetry == beforeRetry)
        print("PASS: official helper A → B, added turn in B, B → A, complete two-turn history across helper restart, idempotent retry")
        try appendTurn(original, number: 3)
        let three = try NativeHistoryLoader.load(binary: binary, home: a.codexHome(in: root), project: project.path, threadID: tid, hydrate: true)
        let forward = try await coordinator.migrate(thread: thread(a, file: original), source: a, target: b, root: root, binary: binary)
        guard forward.status == "verified" else { fatalError("Forward: \(forward.failure?.code ?? forward.status)") }
        precondition(forward.evidence == three && three.turns == 3)
        let cleanA = try Data(contentsOf: original)
        try appendTurn(original, number: 4)
        let staleBeforeA = try NativeFiles.inventory(a.codexHome(in: root)), staleBeforeB = try NativeFiles.inventory(b.codexHome(in: root))
        do { _ = try await coordinator.migrate(thread: thread(a, file: original), source: a, target: b, root: root, binary: binary); fatalError("Accepted stale owner") }
        catch let error as AppFailure { precondition(error.code == "owner") }
        let staleAfterA = try NativeFiles.inventory(a.codexHome(in: root)), staleAfterB = try NativeFiles.inventory(b.codexHome(in: root))
        precondition(staleAfterA == staleBeforeA && staleAfterB == staleBeforeB)
        try appendTurn(received, number: 5)
        let beforeA = try NativeFiles.inventory(a.codexHome(in: root)), beforeB = try NativeFiles.inventory(b.codexHome(in: root))
        do { _ = try await coordinator.migrate(thread: thread(b, file: received), source: b, target: a, root: root, binary: binary); fatalError("Accepted divergent histories") }
        catch let error as AppFailure { precondition(error.code == "diverged") }
        let afterA = try NativeFiles.inventory(a.codexHome(in: root)); precondition(afterA == beforeA)
        let afterB = try NativeFiles.inventory(b.codexHome(in: root)); precondition(afterB == beforeB)
        print("PASS: repeated A → B → A → B, third turn preserved, stale owner and divergent fourth turns rejected with both accounts unchanged")
        // Deliberate import failure after the replacement must retain a usable
        // backup and permit restoring the entire stopped destination.
        try cleanA.write(to: original)
        let sourceHash = try NativeFiles.hash(received)
        let failing = NativeMigrationCoordinator(loader: { _,_,_,_,_ in throw NativeMigrationError.helper })
        let failed = try await failing.migrate(thread: thread(b, file: received), source: b, target: a, root: root, binary: binary)
        precondition(failed.status == "failed" && failed.replacedRolloutHash != nil)
        let rolledBack = try await failing.rollback(id: failed.id, target: a, root: root)
        precondition(rolledBack.status == "rolledBack")
        let restored = try Data(contentsOf: original), sourceAfter = try NativeFiles.hash(received)
        precondition(restored == cleanA && sourceAfter == sourceHash)
        print("PASS: injected import failure, complete backup and rollback, source history unchanged")
        let c = Profile(id: UUID(), name: "C", createdAt: Date())
        try NativeFiles.directory(c.codexHome(in: root)); try NativeFiles.directory(c.electronHome(in: root))
        let fullB = try Data(contentsOf: received)
        let baselineOne = root.appendingPathComponent("NativeMigrations/" + first.id.uuidString + "/rollout.jsonl")
        let truncatedB = try Data(contentsOf: baselineOne); try truncatedB.write(to: received)
        do { _ = try await coordinator.migrate(thread: thread(b, file: received), source: b, target: c, root: root, binary: binary); fatalError("Accepted source history regression") }
        catch let error as AppFailure { precondition(error.code == "diverged") }
        let untouchedC = try NativeFiles.inventory(c.codexHome(in: root)); precondition(untouchedC.isEmpty)
        try fullB.write(to: received)
        let occupied = b.electronHome(in: root).appendingPathComponent("SingletonLock")
        try fm.createSymbolicLink(atPath: occupied.path, withDestinationPath: ProcessInfo.processInfo.hostName + "-" + String(getpid()))
        do { _ = try await coordinator.migrate(thread: thread(b, file: received), source: b, target: a, root: root, binary: binary); fatalError("Migrated running source") }
        catch let error as AppFailure { precondition(error.code.hasPrefix("clientLock-pid-")) }
        try fm.removeItem(at: occupied)
        print("PASS: exact relocated history alias, source history regression and running source rejected before writes")
        let long = root.appendingPathComponent("rollout-long.jsonl"), longCopy = root.appendingPathComponent("rollout-long-copy.jsonl")
        try data.write(to: long)
        let longHandle = try FileHandle(forWritingTo: long); try longHandle.seekToEnd()
        let largeRecord: [String: Any] = ["timestamp": "2026-10-12T10:00:01.000Z", "type": "event_msg", "payload": ["type": "token_count", "fixture_padding": String(repeating: "x", count: 12000)]]
        var chunk = try JSONSerialization.data(withJSONObject: largeRecord, options: [.sortedKeys]); chunk.append(10)
        for _ in 0..<12000 { try longHandle.write(contentsOf: chunk) }
        try longHandle.close()
        try NativeFiles.copy(long, to: longCopy)
        let longHash = try NativeMigrationCoordinator.inspectRollout(long, thread: thread(a, file: long))
        let equalLong = try NativeRoundTrip.relation(source: long, target: longCopy, threadID: tid)
        let verifiedHash = try NativeFiles.verifyLoadedRollout(original: long, loaded: longCopy, threadID: tid)
        precondition(equalLong && longHash == verifiedHash)
        print("PASS: history above 128 MiB validates, compares and verifies with bounded streaming")
        try fm.removeItem(at: root)
    }
}
