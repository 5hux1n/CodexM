import Foundation

actor NativeMigrationCoordinator {
    typealias Loader = @Sendable (URL, URL, String, String, Bool) throws -> NativeEvidence
    typealias Probe = @Sendable (URL, URL, String, String, String) throws -> NativeEvidence
    typealias Version = @Sendable (URL, URL) throws -> String
    private let loader: Loader
    private let version: Version
    private let probe: Probe
    init(loader: @escaping Loader = NativeHistoryLoader.load, version: @escaping Version = NativeHistoryLoader.version, probe: @escaping Probe = NativeHistoryLoader.probe) {
        self.loader = loader; self.version = version; self.probe = probe
    }
    private func directory(_ root: URL, _ id: UUID) -> URL { root.appendingPathComponent("NativeMigrations").appendingPathComponent(id.uuidString) }
    private func save(_ record: NativeMigrationRecord, root: URL) throws {
        try NativeFiles.write(record, to: directory(root, record.id).appendingPathComponent("manifest.json"))
    }
    func recent(root: URL) throws -> [NativeMigrationRecord] {
        let parent = root.appendingPathComponent("NativeMigrations")
        try NativeFiles.safe(parent)
        guard NativeFiles.fm.fileExists(atPath: parent.path) else { return [] }
        return try NativeFiles.fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil else { return nil }
            try NativeFiles.safe(url)
            let record = try preflight("history") { try read(root: root, id: UUID(uuidString: url.lastPathComponent)!) }
            return record
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private func read(root: URL, id: UUID) throws -> NativeMigrationRecord {
        let url = directory(root, id).appendingPathComponent("manifest.json")
        try NativeFiles.safe(url)
        guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max < 32 * 1024 * 1024 else { throw NativeMigrationError.invalid }
        let record = try JSONDecoder().decode(NativeMigrationRecord.self, from: Data(contentsOf: url))
        guard record.formatVersion == 1, record.id == id, !record.containsCredentials,
              NativeFiles.included(record.rolloutRelative), record.rolloutRelative.hasPrefix("sessions/"),
              record.before.keys.allSatisfy(NativeFiles.included), record.after.keys.allSatisfy(NativeFiles.included) else { throw NativeMigrationError.invalid }
        return record
    }
    static func inspectRollout(_ url: URL, thread: ThreadMetadata) throws -> String {
        try NativeFiles.safe(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 128 * 1024 * 1024 else { throw NativeMigrationError.invalid }
        let data = try Data(contentsOf: url)
        guard data.last == 10 else { throw NativeMigrationError.changed }
        var meta: [String: Any]?
        let known: Set<String> = ["session_meta", "turn_context", "world_state", "event_msg", "response_item", "token_usage_record", "compacted"]
        for (index, line) in data.split(separator: 10, omittingEmptySubsequences: false).dropLast().enumerated() {
            guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let kind = object["type"] as? String, known.contains(kind) else { throw NativeMigrationError.incompatible }
            if kind == "session_meta", index != 0 { throw NativeMigrationError.invalid }
            if index == 0 {
                guard kind == "session_meta", let payload = object["payload"] as? [String: Any] else { throw NativeMigrationError.invalid }
                meta = payload
            }
        }
        guard let meta, let id = meta["id"] as? String, UUID(uuidString: id) != nil, id == thread.threadID,
              meta["cwd"] as? String == thread.cwd, let cli = meta["cli_version"] as? String,
              !cli.isEmpty, cli.count < 160 else { throw NativeMigrationError.incompatible }
        if (meta["forked_from_id"] != nil && !(meta["forked_from_id"] is NSNull)) || (meta["parent_thread_id"] != nil && !(meta["parent_thread_id"] is NSNull)) || meta["source"] is [String: Any] { throw NativeMigrationError.unsupported }
        return try NativeFiles.hash(url)
    }
    private func sourceURL(_ thread: ThreadMetadata, home: URL) throws -> URL {
        try RolloutSource.resolve(thread: thread, home: home)
    }

    /// Report the failing preflight check without exposing history or database text.
    private func preflight<T>(_ stage: String, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { throw AppFailure.capture(error, operation: "native." + stage) }
    }

    func migrate(thread: ThreadMetadata, source: Profile, target: Profile, root: URL, binary: URL) throws -> NativeMigrationRecord {
        var stage = "validation"
        var targetMayHaveChanged = false
        do {
            guard source.id != target.id, source.id == thread.profileID, !thread.archived else { throw NativeMigrationError.unsupported }
            guard !(try recent(root: root)).contains(where: { $0.targetProfile == target.id && ["importing", "restoring", "failed"].contains($0.status) }) else { throw NativeMigrationError.recovery }
            let sourceHome = source.codexHome(in: root).standardizedFileURL
            let targetHome = target.codexHome(in: root).standardizedFileURL
            try NativeFiles.safe(sourceHome); try NativeFiles.safe(targetHome)
            guard sourceHome != targetHome, !sourceHome.path.hasPrefix(targetHome.path + "/"), !targetHome.path.hasPrefix(sourceHome.path + "/") else { throw NativeMigrationError.invalid }
            var isDirectory: ObjCBool = false
            guard NativeFiles.fm.fileExists(atPath: thread.cwd, isDirectory: &isDirectory), isDirectory.boolValue else { throw CodexMError.handoffProject }
            stage = "occupancy"
            try NativeFiles.stopped(targetHome, electron: target.electronHome(in: root))
            stage = "directory"
            try NativeFiles.directory(targetHome)
            try preflight("sourceSchema") { try NativeFiles.schema(sourceHome, threadID: thread.threadID, source: true) }
            let sourceProject = try preflight("project") { try NativeHistoryLoader.sourceProject(home: sourceHome, threadID: thread.threadID, cwd: thread.cwd) }
            try preflight("targetSchema") { try NativeFiles.schema(targetHome, threadID: thread.threadID, source: false) }
            stage = "initialize"
            let cli = try version(binary, targetHome)
            let original = try preflight("sourcePath") { try sourceURL(thread, home: sourceHome) }
            let originalHash = try preflight("sourceHistory") { try Self.inspectRollout(original, thread: thread) }
            stage = "load"
            let trial = try probe(binary, original, thread.cwd, thread.threadID, originalHash)
            guard try NativeFiles.hash(original) == originalHash else { throw NativeMigrationError.changed }
            stage = "occupancy"
            try NativeFiles.stopped(targetHome, electron: target.electronHome(in: root))
            stage = "inventory"
            let before = try NativeFiles.inventory(targetHome)
            guard !before.keys.contains(where: { $0.contains(thread.threadID) }) else { throw NativeMigrationError.conflict }
            // A valid rollout may have been renamed and not yet indexed by the official DB.
            for key in before.keys where (key.hasPrefix("sessions/") || key.hasPrefix("archived_sessions/")) && key.hasSuffix(".jsonl") {
                let file = try FileHandle(forReadingFrom: targetHome.appendingPathComponent(key))
                let first = try file.read(upToCount: 1024 * 1024) ?? Data(); try file.close()
                guard let end = first.firstIndex(of: 10), let row = try JSONSerialization.jsonObject(with: first[..<end]) as? [String: Any],
                      let meta = row["payload"] as? [String: Any], row["type"] as? String == "session_meta" else { throw NativeMigrationError.incompatible }
                guard meta["id"] as? String != thread.threadID else { throw NativeMigrationError.conflict }
            }
            // A conservative full snapshot of thread storage. Never snapshot auth/config/Electron.
            let size = try before.keys.reduce(Int64(0)) { partial, key in
                partial + Int64(try targetHome.appendingPathComponent(key).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            stage = "diskSpace"
            let space = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard space > size * 2 + 512 * 1024 * 1024 else { throw NativeMigrationError.invalid }
            stage = "package"
            let id = UUID()
            let package = directory(root, id)
            try NativeFiles.directory(package)
            try NativeFiles.copy(original, to: package.appendingPathComponent("rollout.jsonl"))
            guard try NativeFiles.hash(original) == originalHash, try NativeFiles.hash(package.appendingPathComponent("rollout.jsonl")) == originalHash else { throw NativeMigrationError.changed }
            let relative = "sessions/codexm-import/\(original.lastPathComponent)"
            var record = NativeMigrationRecord(id: id, createdAt: Date(), sourceProfile: source.id, targetProfile: target.id,
                threadID: thread.threadID, title: thread.title, project: thread.cwd, targetHome: targetHome.path,
                rolloutRelative: relative, rolloutHash: originalHash, runtimeVersion: cli, before: before)
            try save(record, root: root)
            try NativeFiles.write(["rollout.jsonl": originalHash], to: package.appendingPathComponent("checksums.json"))
            stage = "backup"
            let backup = package.appendingPathComponent("backup")
            try NativeFiles.directory(backup)
            for key in before.keys { try NativeFiles.copy(targetHome.appendingPathComponent(key), to: backup.appendingPathComponent(key)) }
            guard try NativeFiles.inventory(backup) == before, try NativeFiles.inventory(targetHome) == before, try NativeFiles.hash(original) == originalHash else { throw NativeMigrationError.changed }
            stage = "occupancy"
            try NativeFiles.stopped(targetHome, electron: target.electronHome(in: root))
            stage = "import"
            targetMayHaveChanged = true
            record.status = "importing"; try save(record, root: root)
            do {
                try NativeFiles.copy(package.appendingPathComponent("rollout.jsonl"), to: targetHome.appendingPathComponent(relative))
                stage = "importLoad"
                let first = try loader(binary, targetHome, thread.cwd, thread.threadID, true)
                stage = "importRestart"
                let second = try loader(binary, targetHome, thread.cwd, thread.threadID, false)
                stage = "importCompare"
                guard first == second, first == trial else { throw NativeMigrationError.helper }
                stage = "occupancy"
                try NativeFiles.stopped(targetHome, electron: target.electronHome(in: root))
                guard try NativeFiles.hash(original) == originalHash else { throw NativeMigrationError.changed }
                stage = "importRollout"
                record.loadedRolloutHash = try NativeFiles.verifyLoadedRollout(original: package.appendingPathComponent("rollout.jsonl"), loaded: targetHome.appendingPathComponent(relative), threadID: thread.threadID)
                stage = "importDatabase"
                let db = targetHome.appendingPathComponent("state_5.sqlite")
                let rows = try NativeFiles.stoppedDatabaseRows(db, "SELECT rollout_path FROM threads WHERE id=?", bindings: [thread.threadID], diagnosticStage: "importDatabase")
                guard rows.count == 1, URL(fileURLWithPath: rows[0][0]).standardizedFileURL.resolvingSymlinksInPath() == targetHome.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath() else { throw NativeMigrationError.helper }
                // Verify task-history stores covered by migration backup. Auxiliary stores
                // have a separate lifecycle and must not cause a false import failure.
                for url in try NativeFiles.fm.contentsOfDirectory(at: targetHome, includingPropertiesForKeys: nil) where NativeFiles.taskDatabase(url.lastPathComponent) {
                    guard try NativeFiles.stoppedDatabaseRows(url, "PRAGMA integrity_check", diagnosticStage: "importDatabase") == [["ok"]] else { throw NativeMigrationError.helper }
                }
                if let sourceProject {
                    stage = "project"
                    let assigned = try NativeHistoryLoader.assignProject(binary: binary, home: targetHome, threadID: thread.threadID, project: sourceProject, migrationID: record.id)
                    record.importedProjectID = assigned.id
                    record.importedProjectName = assigned.name
                    try NativeFiles.stopped(targetHome, electron: target.electronHome(in: root))
                    guard try NativeFiles.stoppedDatabaseRows(db, "SELECT project_id FROM threads WHERE id=?", bindings: [thread.threadID], diagnosticStage: "project") == [[record.importedProjectID!]],
                          try NativeFiles.stoppedDatabaseRows(db, "PRAGMA integrity_check", diagnosticStage: "project") == [["ok"]] else { throw NativeMigrationDiagnostic(stage: "project", code: "projectVerificationFailed") }
                }
                record.evidence = second; record.status = "verified"
            } catch {
                record.status = "failed"
                record.diagnostic = error as? NativeMigrationDiagnostic
                record.failure = AppFailure.capture(error, operation: "native." + stage)
                record.failure?.impactKey = "diagnostic.targetMayChanged"
                record.failure?.runtimeVersion = cli
                if let failure = record.failure { DiagnosticJournal.record(failure) }
                record.failureCode = (error as? NativeMigrationError).map { "native.error.\($0.rawValue)" } ?? "error.filesystemError"
            }
            // Persist failures as well: the UI can offer a guarded rollback after relaunch.
            stage = "record"
            record.after = try NativeFiles.inventory(targetHome)
            try save(record, root: root)
            return record
        } catch {
            var failure = AppFailure.capture(error, operation: "native." + stage)
            failure.impactKey = targetMayHaveChanged ? "diagnostic.targetMayChanged" : "diagnostic.targetUntouched"
            throw failure
        }
    }
    func rollback(id: UUID, target: Profile, root: URL, recoverInterrupted: Bool = false) throws -> NativeMigrationRecord {
        var record = try preflight("record") { try read(root: root, id: id) }
        let home = target.codexHome(in: root).standardizedFileURL
        let interrupted = ["importing", "restoring"].contains(record.status)
        guard target.id == record.targetProfile, home.path == record.targetHome,
              ["verified", "failed"].contains(record.status) || (recoverInterrupted && interrupted) else { throw NativeMigrationError.recovery }
        try NativeFiles.stopped(home, electron: target.electronHome(in: root))
        let package = directory(root, id), backup = package.appendingPathComponent("backup")
        guard try NativeFiles.inventory(backup) == record.before else { throw NativeMigrationError.invalid }
        if recoverInterrupted && interrupted { record.after = try NativeFiles.inventory(home) }
        guard try NativeFiles.inventory(home) == record.after else { throw NativeMigrationError.rollbackChanged }
        let preserved = package.appendingPathComponent("before-rollback-\(UUID())")
        try NativeFiles.directory(preserved)
        for key in record.after.keys { try NativeFiles.copy(home.appendingPathComponent(key), to: preserved.appendingPathComponent(key)) }
        guard try NativeFiles.inventory(preserved) == record.after, try NativeFiles.inventory(home) == record.after else { throw NativeMigrationError.changed }
        try NativeFiles.stopped(home, electron: target.electronHome(in: root))
        record.status = "restoring"; try save(record, root: root)
        for key in record.after.keys { try NativeFiles.fm.removeItem(at: home.appendingPathComponent(key)) }
        for key in record.before.keys { try NativeFiles.copy(backup.appendingPathComponent(key), to: home.appendingPathComponent(key)) }
        guard try NativeFiles.inventory(home) == record.before else { throw NativeMigrationError.recovery }
        record.status = "rolledBack"; try save(record, root: root)
        return record
    }
}
