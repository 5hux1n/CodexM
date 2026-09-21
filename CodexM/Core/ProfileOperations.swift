import AppKit

extension AppModel {
    func saveProfile(existing: Profile?, name: String, launchOnStartup: Bool, restoreOnLaunch: Bool) async -> Bool {
        guard ready, !metadataMutation, !isQuitting else { return false }
        metadataMutation = true
        defer { metadataMutation = false }
        do {
            let validated = try Profile.validatedName(name)
            if let existing, !profiles.contains(where: { $0.id == existing.id }) { throw CodexMError.profileNotFound }
            var profile = existing.flatMap { edited in profiles.first(where: { $0.id == edited.id }) } ?? Profile(id: UUID(), name: validated, createdAt: Date())
            profile.name = validated; profile.launchOnStartup = launchOnStartup; profile.restoreOnLaunch = restoreOnLaunch
            if profile.isInstalledDefault { profile.launchOnStartup = false; profile.restoreOnLaunch = false }
            if existing == nil { profile.storageDirectory = preferences.accountDataDirectory; try await store.prepare(profile) }
            let previous = profiles
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
            else { profiles.append(profile) }
            guard await persist() else { profiles = previous; return false }
            Log.profile.info("Saved profile metadata")
            return true
        } catch { report(error); return false }
    }

    func delete(_ profile: Profile) async {
        guard !profile.isInstalledDefault else { report(CodexMError.defaultAccountProtected); return }
        guard ready, !metadataMutation, !busyProfiles.contains(profile.id), !state(profile).isActive, !isQuitting else { report(CodexMError.profileBusy); return }
        metadataMutation = true; busyProfiles.insert(profile.id)
        defer { metadataMutation = false; busyProfiles.remove(profile.id) }
        do {
            await refreshProcesses()
            guard instances[profile.id] == nil, !blockedProfiles.contains(profile.id) else { throw CodexMError.profileBusy }
            try await store.assertNotLocked(profile)
            // Finish queued writes before the atomic store transaction below.
            while persisting { try? await Task.sleep(for: .milliseconds(20)) }
            persisting = true
            var snapshot = StoredState(profiles: profiles.filter { $0.id != profile.id }, preferences: preferences, runtimeRecords: records.filter { $0.profileID != profile.id })
            snapshot.preferences.previouslyRunning.remove(profile.id)
            do { try await store.delete(profile, saving: snapshot) }
            catch { persisting = false; throw error }
            profiles.removeAll { $0.id == profile.id }; records.removeAll { $0.profileID == profile.id }
            preferences.previouslyRunning.remove(profile.id)
            states.removeValue(forKey: profile.id); authStates.removeValue(forKey: profile.id)
            persisting = false
            await persist()
            Log.profile.info("Moved a stopped profile to Trash")
        } catch { report(error) }
    }

    var accountDataDirectory: URL { preferences.accountDataDirectory.map { URL(fileURLWithPath: $0) } ?? dataRoot.appendingPathComponent("Profiles") }

    func chooseAccountDataDirectory() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = accountDataDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await relocateAccounts(to: url)
    }

    func relocateAccounts(to url: URL) async {
        guard ready, !metadataMutation, !isQuitting, busyProfiles.isEmpty else { report(CodexMError.profileBusy); return }
        metadataMutation = true; relocatingAccounts = true
        defer { metadataMutation = false; relocatingAccounts = false }
        do {
            await refreshProcesses()
            guard !profiles.contains(where: { !$0.isInstalledDefault && (instances[$0.id] != nil || blockedProfiles.contains($0.id)) }) else { throw CodexMError.profileBusy }
            while persisting { try? await Task.sleep(for: .milliseconds(20)) }
            persisting = true
            defer { persisting = false }
            let state = StoredState(profiles: profiles, preferences: preferences, runtimeRecords: records)
            let updated = try await store.relocateAccounts(to: url, saving: state)
            profiles = updated.profiles; preferences = updated.preferences
        } catch { report(error) }
        if needsSave { await persist() }
    }

}
