import Foundation

extension AppModel {
    func openHandoff(from profile: Profile? = nil) {
        guard ready, !isQuitting else { return }
        if !handoffWorking { handoffSourceID = profile?.id }
        menuPanelCloser?()
        handoffOpener?()
    }
    func launchHandoffTarget(_ profile: Profile) async {
        guard ready, !isQuitting else { return }
        await refreshProcesses()
        if instances[profile.id] == nil { await launch(profile) }
        if instances[profile.id] != nil { await focus(profile, reportFailure: false) }
    }
}

extension AppModel {
    func importNative(thread: ThreadMetadata, source: Profile, target: Profile) async throws -> NativeMigrationRecord {
        guard ready, !previewMode, !isQuitting, !metadataMutation, busyProfiles.isEmpty, !relocatingAccounts,
              let runtime, profiles.contains(where: { $0.id == source.id }), profiles.contains(where: { $0.id == target.id }) else { throw CodexMError.profileBusy }
        metadataMutation = true; busyProfiles.insert(target.id); handoffWorking = true
        defer { metadataMutation = false; busyProfiles.remove(target.id); handoffWorking = false }
        await refreshProcesses()
        guard instances[target.id] == nil, !blockedProfiles.contains(target.id) else { throw NativeMigrationError.busy }
        try await store.prepare(target)
        try await store.assertNotLocked(target)
        return try await nativeMigration.migrate(thread: thread, source: source, target: target, root: dataRoot,
            binary: runtime.appURL.appendingPathComponent("Contents/Resources/codex"))
    }
    func rollbackNative(_ record: NativeMigrationRecord, recoverInterrupted: Bool = false) async throws -> NativeMigrationRecord {
        guard ready, !previewMode, !isQuitting, !metadataMutation, busyProfiles.isEmpty, !relocatingAccounts,
              let target = profiles.first(where: { $0.id == record.targetProfile }) else { throw CodexMError.profileBusy }
        metadataMutation = true; busyProfiles.insert(target.id); handoffWorking = true
        defer { metadataMutation = false; busyProfiles.remove(target.id); handoffWorking = false }
        await refreshProcesses()
        guard instances[target.id] == nil else { throw NativeMigrationError.busy }
        return try await nativeMigration.rollback(id: record.id, target: target, root: dataRoot, recoverInterrupted: recoverInterrupted)
    }
}
