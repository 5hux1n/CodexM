import Foundation

// Small adapters isolate the real storage, coordinator and official loader
// from UI/localization. No loader or projection behavior is mocked.
enum CodexMError: String, Error { case unsafePath, handoffTranscript, handoffProject, corruptStorage, defaultAccountProtected, directoryNotEmpty, filesystemError, profileBusy, storageLocked, invalidName, handoffNoDatabase, handoffSchema }
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
        let existing = try Data(contentsOf: file).split(separator: 10)
        let header = try JSONSerialization.jsonObject(with: Data(existing[0])) as! [String: Any]
        let paginated = (header["payload"] as! [String: Any])["history_mode"] as? String == "paginated"
        var ordinal = ((try JSONSerialization.jsonObject(with: Data(existing.last!)) as! [String: Any])["ordinal"] as? Int ?? -1) + 1
        for (index, var record) in records.enumerated() {
            if paginated {
                if index == 2 || index == 4 {
                    record["payload"] = ["type": "item_completed", "thread_id": (header["payload"] as! [String: Any])["id"]!, "turn_id": turn,
                        "item": ["type": index == 2 ? "UserMessage" : "AgentMessage", "id": UUID().uuidString.lowercased(), "content": [["type": index == 2 ? "text" : "Text", "text": index == 2 ? "Fixture request \(number)" : "Fixture response \(number)", "text_elements": []]], "phase": "final_answer", "client_id": NSNull()], "started_at_ms": 1, "completed_at_ms": 2]
                }
                record["ordinal"] = ordinal; ordinal += 1
            }
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]); data.append(10); try handle.write(contentsOf: data)
        }
    }
    static func main() async throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        // Optional read-only diagnostic: only private, credential-free copies
        // are opened by the official helper. Output contains counts, never text.
        if CommandLine.arguments.count == 6 {
            let home = URL(fileURLWithPath: CommandLine.arguments[2])
            let rollout = URL(fileURLWithPath: CommandLine.arguments[3])
            let project = CommandLine.arguments[4], threadID = CommandLine.arguments[5]
            let temporary = fm.temporaryDirectory.appendingPathComponent("CodexM-fork-check-\(UUID())").resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: temporary) }
            let selected = ThreadMetadata(profileID: UUID(), threadID: threadID, title: "Private verification", cwd: project, rolloutPath: rollout.path, updatedAt: Date(), archived: false)
            _ = try NativeMigrationCoordinator.inspectRollout(rollout, thread: selected)
            let snapshot = try NativePortableRollout.prepare(rollout, home: home, workspace: temporary)
            _ = try NativeMigrationCoordinator.inspectRollout(snapshot.rollout, thread: selected)
            guard let reference = snapshot.referenceHome else { fatalError("No inherited history") }
            let inherited = try NativeHistoryLoader.load(binary: binary, home: reference, project: project, threadID: threadID, hydrate: true)
            let portable = try NativeHistoryLoader.probe(binary: binary, rollout: snapshot.rollout, project: project, threadID: threadID, expectedHash: NativeFiles.hash(snapshot.rollout))
            let fullHome = temporary.appendingPathComponent("full")
            try NativeFiles.copy(snapshot.rollout, to: fullHome.appendingPathComponent("sessions/codexm-import/" + rollout.lastPathComponent))
            let full = try NativeHistoryLoader.load(binary: binary, home: fullHome, project: project, threadID: threadID, hydrate: true)
            let suffix = try NativeHistoryLoader.suffix(binary: binary, home: fullHome, project: project, threadID: threadID, skipping: portable.turns - inherited.turns)
            precondition(full == portable && suffix == inherited)
            try snapshot.validate()
            print("PASS: private real-fork comparison: \(portable.turns) turns, \(portable.items) items, \(snapshot.inputs.count) source files unchanged")
            return
        }
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
        let sourceProjectID = UUID().uuidString
        let sidebarSource: [String: Any] = ["local-projects": [sourceProjectID: ["id": sourceProjectID, "name": "Fixture Project", "rootPaths": [project.path]]],
            "thread-project-assignments": [tid: ["projectKind": "local", "projectId": sourceProjectID]], "electron-mac-push-deregistration-token": "private-source-sentinel"]
        try JSONSerialization.data(withJSONObject: sidebarSource).write(to: a.codexHome(in: root).appendingPathComponent(".codex-global-state.json"))
        let unrelatedProjectID = UUID().uuidString
        let targetSidebar: [String: Any] = ["local-projects": [unrelatedProjectID: ["id": unrelatedProjectID, "name": "Unrelated project", "rootPaths": [root.appendingPathComponent("unrelated").path]]],
            "project-order": [unrelatedProjectID], "selected-project": ["type": "local", "projectId": unrelatedProjectID], "electron-mac-push-deregistration-token": "private-target-sentinel"]
        let targetState = b.codexHome(in: root).appendingPathComponent(".codex-global-state.json")
        try JSONSerialization.data(withJSONObject: targetSidebar).write(to: targetState)
        let coordinator = NativeMigrationCoordinator()
        let first = try await coordinator.migrate(thread: thread(a, file: original), source: a, target: b, root: root, binary: binary)
        guard first.status == "verified" else { fatalError("Initial import: \(first.failure?.code ?? first.failureCode ?? first.status)") }
        precondition(first.importedProjectName == "Fixture Project" && first.desktopStateBefore != nil)
        let displayName = try NativeHistoryLoader.hasDisplayName(binary: binary, home: b.codexHome(in: root), threadID: tid, name: "Fixture")
        let projectVisible = try NativeDesktopState.visible(home: b.codexHome(in: root), threadID: tid, project: NativeProject(name: "Fixture Project", roots: [project.path]))
        precondition(displayName && projectVisible)
        let listed = try await ThreadStore().readThreads(profile: b, root: root)
        precondition(listed.first(where: { $0.threadID == tid })?.title == "Fixture")
        let registeredState = try JSONSerialization.jsonObject(with: Data(contentsOf: targetState)) as! [String: Any]
        precondition(registeredState["electron-mac-push-deregistration-token"] as? String == "private-target-sentinel")
        precondition((registeredState["selected-project"] as! [String: Any])["projectId"] as? String == unrelatedProjectID)
        precondition((registeredState["local-projects"] as! [String: Any])[unrelatedProjectID] != nil)
        let displayBackup = try NativeDesktopState.validateSnapshot(first.desktopStateBefore!)
        precondition(displayBackup["electron-mac-push-deregistration-token"] == nil)
        precondition(!String(decoding: first.desktopStateBefore!, as: UTF8.self).contains("private-target-sentinel"))
        let encoded = try JSONEncoder().encode(first)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("private-target-sentinel") && !String(decoding: encoded, as: UTF8.self).contains("private-source-sentinel"))
        try NativeHistoryLoader.setName(binary: binary, home: b.codexHome(in: root), threadID: tid, name: "User renamed task")
        let renamedRetry = try await coordinator.migrate(thread: thread(a, file: original), source: a, target: b, root: root, binary: binary)
        precondition(renamedRetry.id == first.id)
        let keptName = try NativeHistoryLoader.displayName(binary: binary, home: b.codexHome(in: root), threadID: tid)
        precondition(keptName == "User renamed task")
        try NativeHistoryLoader.setName(binary: binary, home: b.codexHome(in: root), threadID: tid, name: "Fixture")
        // A legacy successful import can be retried to repair its missing
        // sidebar registration, with a fresh backup and the same task identity.
        try JSONSerialization.data(withJSONObject: targetSidebar).write(to: targetState)
        let visibilityRepair = try await coordinator.migrate(thread: thread(a, file: original), source: a, target: b, root: root, binary: binary)
        precondition(visibilityRepair.status == "verified" && visibilityRepair.id != first.id)
        let repairedVisible = try NativeDesktopState.visible(home: b.codexHome(in: root), threadID: tid, project: NativeProject(name: "Fixture Project", roots: [project.path]))
        precondition(repairedVisible)
        let repairedSidebar = try Data(contentsOf: targetState)
        // Sidebar edits after import must prevent rollback; restore only the
        // synthetic edit before testing full storage + sidebar rollback.
        var editedSidebar = try JSONSerialization.jsonObject(with: Data(contentsOf: targetState)) as! [String: Any]
        editedSidebar["project-order"] = ["synthetic-user-edit"]
        try JSONSerialization.data(withJSONObject: editedSidebar).write(to: targetState)
        do { _ = try await coordinator.rollback(id: visibilityRepair.id, target: b, root: root); fatalError("Overwrote changed sidebar") }
        catch NativeMigrationError.rollbackChanged {}
        try repairedSidebar.write(to: targetState)
        // Generated IDs are stable because registration reuses the server ID.
        _ = try await coordinator.rollback(id: visibilityRepair.id, target: b, root: root)
        let restoredSidebar = try NativeDesktopState.snapshot(b.codexHome(in: root))
        precondition(restoredSidebar == visibilityRepair.desktopStateBefore)
        _ = try await coordinator.migrate(thread: thread(a, file: original), source: a, target: b, root: root, binary: binary)
        print("PASS: display name, sidebar project and membership, user rename and unrelated preferences retained, no auth values in backup, legacy import display repair and guarded sidebar rollback")
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
        // A paginated fork can depend on an unindexed, rotated generation,
        // which itself inherits only a prefix of an earlier rollout.
        let d = Profile(id: UUID(), name: "Fork source", createdAt: Date()), e = Profile(id: UUID(), name: "Fork target", createdAt: Date())
        for profile in [d,e] { try NativeFiles.directory(profile.codexHome(in: root)); try NativeFiles.directory(profile.electronHome(in: root)) }
        let dh = d.codexHome(in: root), eh = e.codexHome(in: root)
        let parentID = UUID().uuidString.lowercased(), generationID = UUID().uuidString.lowercased(), forkID = UUID().uuidString.lowercased()
        func writeMeta(_ payload: [String: Any], to file: URL) throws {
            try NativeFiles.directory(file.deletingLastPathComponent())
            var row: [String: Any] = ["timestamp": "2026-10-12T10:00:00.000Z", "type": "session_meta", "payload": payload]
            if payload["history_mode"] as? String == "paginated" { row["ordinal"] = (payload["history_base"] as? [String: Any])?["end_ordinal_exclusive"] as? Int ?? 0 }
            var bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); bytes.append(10); try bytes.write(to: file)
        }
        var parentMeta = meta["payload"] as! [String: Any]; parentMeta["id"] = parentID; parentMeta["history_mode"] = "paginated"
        let parentFile = dh.appendingPathComponent("sessions/2026/10/12/rollout-2026-10-12T10-00-00-\(parentID).jsonl")
        try writeMeta(parentMeta, to: parentFile); try appendTurn(parentFile, number: 1)
        let parentBytes = try Data(contentsOf: parentFile).count
        try appendTurn(parentFile, number: 8) // Excluded by the inherited cutoff.
        var generationMeta = parentMeta
        generationMeta["history_base"] = ["thread_id": parentID, "end_byte_offset": parentBytes, "end_ordinal_exclusive": 7]
        let generationFile = dh.appendingPathComponent("sessions/2026/10/12/rollout-2026-10-12T10-00-01-\(parentID)_\(generationID).jsonl")
        try writeMeta(generationMeta, to: generationFile); try appendTurn(generationFile, number: 2)
        let generationBytes = try Data(contentsOf: generationFile).count
        try appendTurn(generationFile, number: 9) // Also excluded.
        var forkMeta = parentMeta; forkMeta["id"] = forkID; forkMeta["forked_from_id"] = parentID
        forkMeta["forked_from_ordinal_exclusive"] = 14
        forkMeta["history_base"] = ["thread_id": generationID, "end_byte_offset": generationBytes, "end_ordinal_exclusive": 14]
        let forkFile = dh.appendingPathComponent("sessions/2026/10/12/rollout-2026-10-12T10-00-02-\(forkID).jsonl")
        try writeMeta(forkMeta, to: forkFile); try appendTurn(forkFile, number: 3)
        func forkThread(_ profile: Profile, _ file: URL) -> ThreadMetadata {
            ThreadMetadata(profileID: profile.id, threadID: forkID, title: "Fork fixture", cwd: project.path, rolloutPath: file.path, updatedAt: Date(), archived: false)
        }
        let forkEvidence = try NativeHistoryLoader.load(binary: binary, home: dh, project: project.path, threadID: forkID, hydrate: true)
        precondition(forkEvidence.turns > 0 && forkEvidence.turns <= 3)
        let sourceBefore = try NativeFiles.inventory(dh)
        let forkImport = try await coordinator.migrate(thread: forkThread(d, forkFile), source: d, target: e, root: root, binary: binary)
        guard forkImport.status == "verified" else { fatalError("Fork import: \(forkImport.failure?.code ?? forkImport.status)") }
        precondition(forkImport.evidence?.turns == 3 && forkImport.evidence?.items == 6)
        let importedFork = eh.appendingPathComponent(forkImport.rolloutRelative)
        let portableMeta = try JSONSerialization.jsonObject(with: NativeRolloutReader(importedFork).next()!) as! [String: Any]
        precondition((portableMeta["payload"] as! [String: Any])["history_base"] == nil)
        let importedInventory = try NativeFiles.inventory(eh)
        precondition(!importedInventory.keys.contains(where: { $0.contains(parentID) || $0.contains(generationID) }))
        let forkSourceAfter = try NativeFiles.inventory(dh); precondition(sourceBefore == forkSourceAfter)
        try appendTurn(importedFork, number: 4)
        let dependentBeforeReturn = try Data(contentsOf: forkFile)
        let forkFailure = try await failing.migrate(thread: forkThread(e, importedFork), source: e, target: d, root: root, binary: binary)
        precondition(forkFailure.status == "failed")
        _ = try await failing.rollback(id: forkFailure.id, target: d, root: root)
        let dependentAfterRollback = try Data(contentsOf: forkFile)
        precondition(dependentAfterRollback == dependentBeforeReturn)
        let forkReturn = try await coordinator.migrate(thread: forkThread(e, importedFork), source: e, target: d, root: root, binary: binary)
        guard forkReturn.status == "verified" else { fatalError("Fork return: \(forkReturn.failure?.code ?? forkReturn.status)") }
        precondition(forkReturn.evidence?.turns == 4)
        let forkRestart = try NativeHistoryLoader.load(binary: binary, home: dh, project: project.path, threadID: forkID, hydrate: false)
        precondition(forkRestart == forkReturn.evidence)
        print("PASS: nested paginated fork, unindexed rotated base, exact cutoffs exclude later parent turns, official full-history reconstruction and local suffix verification, source unchanged, failed return rollback, return and restart preserve four turns")
        let bad = root.appendingPathComponent("bad-fork.jsonl")
        var brokenMeta = forkMeta; brokenMeta["history_base"] = ["thread_id": generationID, "end_byte_offset": generationBytes - 1, "end_ordinal_exclusive": 14]
        try writeMeta(brokenMeta, to: bad); try appendTurn(bad, number: 3)
        do { _ = try NativePortableRollout.prepare(bad, home: dh, workspace: root.appendingPathComponent("bad-output")); fatalError("Accepted partial base record") }
        catch NativeMigrationError.historyBase {}
        brokenMeta["history_base"] = ["thread_id": UUID().uuidString.lowercased(), "end_byte_offset": generationBytes, "end_ordinal_exclusive": 14]
        try writeMeta(brokenMeta, to: bad); try appendTurn(bad, number: 3)
        do { _ = try NativePortableRollout.prepare(bad, home: dh, workspace: root.appendingPathComponent("missing-output")); fatalError("Accepted missing base") }
        catch NativeMigrationError.historyBase {}
        brokenMeta["history_base"] = ["thread_id": generationID, "end_byte_offset": generationBytes, "end_ordinal_exclusive": Int.max]
        try writeMeta(brokenMeta, to: bad)
        do { _ = try NativePortableRollout.prepare(bad, home: dh, workspace: root.appendingPathComponent("overflow-output")); fatalError("Accepted overflowing ordinal") }
        catch NativeMigrationError.historyBase {}
        try writeMeta(forkMeta, to: bad); try appendTurn(bad, number: 3)
        let duplicate = dh.appendingPathComponent("sessions/duplicate/" + generationFile.lastPathComponent)
        try NativeFiles.copy(generationFile, to: duplicate)
        do { _ = try NativePortableRollout.prepare(bad, home: dh, workspace: root.appendingPathComponent("duplicate-output")); fatalError("Accepted ambiguous generation") }
        catch NativeMigrationError.historyBase {}
        try fm.removeItem(at: duplicate)
        let savedGeneration = try Data(contentsOf: generationFile)
        var cyclic = generationMeta; cyclic["history_base"] = ["thread_id": generationID, "end_byte_offset": generationBytes, "end_ordinal_exclusive": 14]
        try writeMeta(cyclic, to: generationFile); try appendTurn(generationFile, number: 2)
        do { _ = try NativePortableRollout.prepare(bad, home: dh, workspace: root.appendingPathComponent("cycle-output")); fatalError("Accepted cyclic inheritance") }
        catch NativeMigrationError.historyBase {}
        try savedGeneration.write(to: generationFile)
        let stableFork = try Data(contentsOf: forkFile)
        brokenMeta["history_base"] = ["thread_id": UUID().uuidString.lowercased(), "end_byte_offset": generationBytes, "end_ordinal_exclusive": 14]
        try writeMeta(brokenMeta, to: forkFile); try appendTurn(forkFile, number: 3)
        let negativeBeforeSource = try NativeFiles.inventory(dh), negativeBeforeTarget = try NativeFiles.inventory(eh)
        do { _ = try await coordinator.migrate(thread: forkThread(d, forkFile), source: d, target: e, root: root, binary: binary); fatalError("Imported missing inherited history") }
        catch let error as AppFailure { precondition(error.code == "historyBase") }
        let negativeAfterSource = try NativeFiles.inventory(dh), negativeAfterTarget = try NativeFiles.inventory(eh)
        precondition(negativeAfterSource == negativeBeforeSource && negativeAfterTarget == negativeBeforeTarget)
        try stableFork.write(to: forkFile)
        print("PASS: missing dependency, ambiguous generation, cyclic inheritance, overflowing ordinal and partial-record cutoff rejected; failed preflight leaves both accounts unchanged")
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
