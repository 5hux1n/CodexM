import AppKit
import ApplicationServices
import ServiceManagement

extension AppModel {
    func refresh() async {
        guard !refreshing, !loadFailed, !isQuitting else { return }
        refreshing = true
        defer { refreshing = false }
        accessibilityGranted = AXIsProcessTrusted()
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        await detectRuntime()
        await refreshProcesses()
        await refreshWindows()
        await refreshAuth()
    }

    func refreshProcesses() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        var paths = Set(records.map { $0.identity.executable })
        paths.formUnion(runningApps.compactMap { $0.executableURL?.path })
        if let runtime { paths.insert(runtime.executableURL.path) }
        let found = await runtimeService.scan(executables: paths)
        let identities = Set(found)
        for (id, instance) in instances where !identities.contains(instance.identity) && !busyProfiles.contains(id) {
            if !instance.recovered {
                if let exit = await runtimeService.exitOutcome(pid: instance.pid) {
                    let crashed = !terminationRequests.contains(id) && (exit.signaled || exit.status != 0)
                    await forgetInstance(profileID: id, expected: instance.identity, crashed: crashed)
                } else if let current = await runtimeService.currentIdentity(pid: instance.pid), current != instance.identity {
                    // A changed identity is quarantined, never controlled as the old instance.
                    await forgetInstance(profileID: id, expected: instance.identity, crashed: false)
                }
                // Wait for the Process callback if NSWorkspace reported termination first.
            } else {
                // Reattached processes have no wait status. Do not invent a crash diagnosis.
                await forgetInstance(profileID: id, expected: instance.identity, crashed: false)
            }
        }
        for record in records where identities.contains(record.identity) && profiles.contains(where: { $0.id == record.profileID }) {
            if instances[record.profileID] == nil {
                instances[record.profileID] = CodexInstance(id: UUID(), profileID: record.profileID, identity: record.identity, launchedAt: record.launchedAt, state: .running, recovered: true)
                states[record.profileID] = .running
            }
        }
        if let profile = profiles.first(where: \.isInstalledDefault), instances[profile.id] == nil, let runtime,
           let identity = await runtimeService.installedDefaultIdentity(profile: profile, root: dataRoot, runtime: runtime) {
            instances[profile.id] = CodexInstance(id: UUID(), profileID: profile.id, identity: identity, launchedAt: Date(timeIntervalSince1970: TimeInterval(identity.startSeconds)), state: .running, recovered: true)
            states[profile.id] = .running
        }
        let managed = Set(instances.values.map(\.identity))
        externalInstances = found.filter { !managed.contains($0) }
        var blocked: Set<UUID> = []
        for external in externalInstances {
            if let args = await runtimeService.arguments(pid: external.pid), let directory = ProcessProbe.userDataDirectory(in: args) {
                let path = URL(fileURLWithPath: directory).standardizedFileURL.path
                for profile in profiles where profile.electronHome(in: dataRoot).standardizedFileURL.path == path { blocked.insert(profile.id) }
            }
        }
        blockedProfiles = blocked
    }

    func windowLabel(_ window: CodexWindow, in windows: [CodexWindow]) -> String {
        if let note = windowNotes[window.id], !note.isEmpty { return note }
        let title = window.title.isEmpty ? text("window.untitled") : window.title
        let duplicates = windows.filter { $0.title == window.title }
        guard duplicates.count > 1, let index = duplicates.firstIndex(where: { $0.id == window.id }) else { return title }
        return text("window.distinguished", title, index + 1)
    }

    func refreshWindowsAfterCreation(profileID: UUID, identity: ProcessIdentity, previousCount: Int) {
        Task { [weak self] in
            for _ in 0..<20 {
                guard let self, self.instances[profileID]?.identity == identity else { return }
                self.refreshAccessibility()
                await self.refreshWindows()
                if (self.windows[profileID]?.count ?? 0) > previousCount { return }
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
        }
    }

    func refreshWindows() async {
        guard !windowsRefreshing else { return }
        windowsRefreshing = true
        defer { windowsRefreshing = false }
        let snapshot = instances
        for (id, instance) in snapshot {
            let found = await windowService.enumerate(identity: instance.identity)
            guard instances[id]?.identity == instance.identity else { continue }
            let removed = Set((self.windows[id] ?? []).map(\.id)).subtracting(found.map(\.id))
            for id in removed { windowNotes.removeValue(forKey: id) }
            windows[id] = found
            if let focused = found.first(where: \.isFocused) { lastWindows[id] = focused.id }
        }
    }

    func refreshAuth() async {
        for profile in profiles where !profile.isInstalledDefault && instances[profile.id] != nil {
            let metadata = await authMonitor.metadata(profile: profile, root: dataRoot)
            guard instances[profile.id] != nil else { continue }
            guard let metadata else { authStates[profile.id] = .unknown; continue }
            let previous = authMetadata[profile.id]
            authMetadata[profile.id] = metadata
            if var pending = pendingLogins[profile.id], Date().timeIntervalSince(pending.createdAt) < 300 {
                if let previous, metadata.exists, metadata.size > 0, metadata != previous, pending.evidenceAt == nil {
                    pending.evidenceAt = Date(); pendingLogins[profile.id] = pending
                    Log.auth.info("Authentication metadata changed; credentials were not read")
                }
                authStates[profile.id] = pending.evidenceAt == nil ? .signingIn : .signedIn
            } else {
                pendingLogins.removeValue(forKey: profile.id)
                authStates[profile.id] = metadata.exists && metadata.size > 0 ? .signedIn : .signedOut
            }
        }
        pendingLogins = pendingLogins.filter { Date().timeIntervalSince($0.value.createdAt) < 300 }
        let pids = Set(instances.values.map(\.pid)).union(externalInstances.map(\.pid))
        if accessibilityGranted, let id = FocusRecoveryPolicy.target(pending: Array(pendingLogins.values), now: Date(), frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, instances: instances, codexPIDs: pids),
           let profile = profiles.first(where: { $0.id == id }) {
            pendingLogins.removeValue(forKey: id)
            await focus(profile, reportFailure: false)
        }
    }
}
