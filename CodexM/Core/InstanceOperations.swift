import AppKit
import ApplicationServices

extension AppModel {
    func activate(_ profile: Profile) async {
        guard ready, !isQuitting else { return }
        if state(profile) == .running {
            await focus(profile)
        } else if !state(profile).isActive { await launch(profile) }
    }

    func launch(_ profile: Profile) async {
        guard !previewMode else { report(CodexMError.unavailable); return }
        guard ready, !isQuitting, !metadataMutation, let profile = profiles.first(where: { $0.id == profile.id }), !busyProfiles.contains(profile.id), !state(profile).isActive else { return }
        // This reservation precedes the first suspension. Every entry point uses it.
        busyProfiles.insert(profile.id); states[profile.id] = .launching
        defer { busyProfiles.remove(profile.id) }
        do {
            let migrations = try await nativeMigration.recent(root: dataRoot)
            guard !migrations.contains(where: { $0.targetProfile == profile.id && ["importing", "restoring", "failed"].contains($0.status) }) else { throw NativeMigrationError.recovery }
            await refreshProcesses()
            if instances[profile.id] != nil { states[profile.id] = .running; await focus(profile); return }
            guard !blockedProfiles.contains(profile.id) else { throw CodexMError.ambiguousInstance }
            guard let runtime else { throw CodexMError.codexNotFound }
            try await store.prepare(profile)
            try await store.assertNotLocked(profile)
            let metadata = profile.isInstalledDefault ? nil : await authMonitor.metadata(profile: profile, root: dataRoot)
            let launchID = UUID()
            let identity = try await runtimeService.launch(profile, root: dataRoot, runtime: runtime) { [weak self] pid, status, signal in
                Task { @MainActor in await self?.processExited(profileID: profile.id, pid: pid, instanceID: launchID, status: status, signal: signal) }
            }
            let now = Date()
            instances[profile.id] = CodexInstance(id: launchID, profileID: profile.id, identity: identity, launchedAt: now, state: .running, recovered: false)
            states[profile.id] = .running
            records.removeAll { $0.profileID == profile.id }
            records.append(RuntimeRecord(profileID: profile.id, identity: identity, launchedAt: now))
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index].lastLaunchedAt = now }
            preferences.previouslyRunning.insert(profile.id)
            authMetadata[profile.id] = metadata
            if let metadata, !metadata.exists {
                pendingLogins[profile.id] = PendingLogin(profileID: profile.id, createdAt: now)
                authStates[profile.id] = .signingIn
            }
            await persist()
            await refreshWindows()
            refreshWindowsAfterCreation(profileID: profile.id, identity: identity, previousCount: 0)
            Log.process.info("Launched a managed instance")
        } catch { states[profile.id] = .error; report(error) }
    }

    func focus(_ profile: Profile, windowID: UUID? = nil, reportFailure: Bool = true) async {
        focusRequestSerial &+= 1
        let requestSerial = focusRequestSerial
        windowHighlight.hide()
        menuPanelCloser?()
        do { _ = try await focusWindow(profile, windowID: windowID, requestSerial: requestSerial) }
        catch is CancellationError { }
        catch { if reportFailure { report(error) } }
    }

    private func focusWindow(_ profile: Profile, windowID: UUID?, requestSerial: UInt64? = nil) async throws -> (ProcessIdentity, UUID, CGRect)? {
        try checkFocusRequest(requestSerial)
        guard let instance = instances[profile.id], instance.state == .running,
              await runtimeService.matches(instance.identity), let app = NSRunningApplication(processIdentifier: instance.pid) else {
            throw CodexMError.processChanged
        }
        try checkFocusRequest(requestSerial)
        refreshAccessibility()
        if !accessibilityGranted {
            guard windowID == nil else { throw CodexMError.accessibilityDenied }
            app.unhide()
            guard app.activate(from: .current, options: []) else { throw CodexMError.windowFocusFailed }
            return nil
        }
        let remembered = lastWindows[profile.id].flatMap { id in windows[profile.id]?.contains(where: { $0.id == id }) == true ? id : nil }
        var selectedID = windowID ?? remembered
        for attempt in 0..<5 {
            try checkFocusRequest(requestSerial)
            guard instances[profile.id]?.identity == instance.identity else { throw CodexMError.processChanged }
            // Select the exact window before activation can restore another one.
            selectedID = try await windowService.raise(identity: instance.identity, windowID: selectedID, allowFallback: attempt == 0 && windowID == nil)
            try checkFocusRequest(requestSerial)
            app.unhide()
            _ = app.activate(from: .current, options: [])
            try await Task.sleep(for: .milliseconds(attempt == 0 ? 100 : 150))
            try checkFocusRequest(requestSerial)
            selectedID = try await windowService.raise(identity: instance.identity, windowID: selectedID)
            try checkFocusRequest(requestSerial)
            if let id = selectedID, let frame = await windowService.focusedFrame(identity: instance.identity, windowID: id) {
                try checkFocusRequest(requestSerial)
                lastWindows[profile.id] = id
                return (instance.identity, id, frame)
            }
        }
        throw CodexMError.windowFocusFailed
    }

    private func checkFocusRequest(_ requestSerial: UInt64?) throws {
        try Task.checkCancellation()
        if let requestSerial, requestSerial != focusRequestSerial { throw CancellationError() }
    }

    func previewWindow(_ profile: Profile, windowID: UUID, onFailure: @escaping (String) -> Void = { _ in }) -> Task<Void, Never>? {
        guard !Task.isCancelled, !isQuitting, !busyProfiles.contains(profile.id),
              let instance = instances[profile.id], instance.state == .running,
              windows[profile.id]?.contains(where: { $0.id == windowID }) == true else { return nil }
        return Task { [weak self] in
            guard let self else { return }
            do {
                guard let (identity, id, frame) = try await self.focusWindow(profile, windowID: windowID) else { return }
                try Task.checkCancellation()
                self.windowHighlight.show(quartzFrame: frame)
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(200))
                    let updated = await self.windowService.focusedFrame(identity: identity, windowID: id)
                    try Task.checkCancellation()
                    guard let frame = updated else { self.windowHighlight.hide(); return }
                    self.windowHighlight.show(quartzFrame: frame)
                }
            } catch is CancellationError { }
              catch { if !Task.isCancelled { self.windowHighlight.hide(); onFailure(error.localizedDescription) } }
        }
    }

    func newWindow(_ profile: Profile) async {
        menuPanelCloser?()
        refreshAccessibility()
        guard accessibilityGranted else { report(CodexMError.accessibilityDenied); return }
        guard let instance = instances[profile.id], instance.state == .running else { return }
        let count = windows[profile.id]?.count ?? 0
        do {
            await focus(profile, reportFailure: false)
            try await windowService.newWindow(identity: instance.identity)
            refreshWindowsAfterCreation(profileID: profile.id, identity: instance.identity, previousCount: count)
        }
        catch { report(error) }
    }

    func stop(_ profile: Profile, restart: Bool = false, force: Bool = false) async {
        guard let instance = instances[profile.id], !busyProfiles.contains(profile.id) else { return }
        // Never stop an ambiguously shared process, even if stale records map it twice.
        guard !instances.contains(where: { $0.key != profile.id && $0.value.pid == instance.pid }) else {
            report(CodexMError.ambiguousInstance); return
        }
        busyProfiles.insert(profile.id); terminationRequests.insert(profile.id)
        states[profile.id] = .terminating; instances[profile.id]?.state = .terminating
        timedOutProfiles.remove(profile.id)
        guard await runtimeService.matches(instance.identity) else {
            busyProfiles.remove(profile.id); await forgetInstance(profileID: profile.id, expected: instance.identity, crashed: false); return
        }
        // Application-level quit can fan out across instances of the same bundle.
        // Terminate only this account's identity- and ownership-checked positive PID.
        let requested = await runtimeService.terminate(instance.identity, profile: profile, root: dataRoot, force: force)
        if !requested {
            busyProfiles.remove(profile.id); states[profile.id] = .running; instances[profile.id]?.state = .running
            terminationRequests.remove(profile.id); report(CodexMError.terminationFailed); return
        }
        for _ in 0..<40 {
            if !(await runtimeService.matches(instance.identity)) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let alive = await runtimeService.matches(instance.identity)
        busyProfiles.remove(profile.id)
        if alive {
            states[profile.id] = .running; instances[profile.id]?.state = .running
            timedOutProfiles.insert(profile.id); terminationRequests.remove(profile.id)
            if !isQuitting { forceQuitProfile = profile; openDashboard() }
        } else {
            await forgetInstance(profileID: profile.id, expected: instance.identity, crashed: false)
            if restart, !isQuitting { await launch(profile) }
        }
    }

    func processExited(profileID: UUID, pid: Int32, instanceID: UUID, status: Int32, signal: Bool) async {
        // Process can exit before launch's actor continuation has registered it.
        if busyProfiles.contains(profileID), instances[profileID] == nil {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard let instance = instances[profileID], instance.pid == pid, instance.id == instanceID else { return }
        let crashed = !terminationRequests.contains(profileID) && (signal || status != 0)
        await forgetInstance(profileID: profileID, expected: instance.identity, crashed: crashed)
    }

    func forgetInstance(profileID: UUID, expected: ProcessIdentity, crashed: Bool) async {
        guard instances[profileID]?.identity == expected else { return }
        guard let previous = instances.removeValue(forKey: profileID) else { return }
        states[profileID] = crashed ? .crashed : .stopped
        for window in windows[profileID] ?? [] { windowNotes.removeValue(forKey: window.id) }
        windows.removeValue(forKey: profileID); lastWindows.removeValue(forKey: profileID)
        pendingLogins.removeValue(forKey: profileID); timedOutProfiles.remove(profileID)
        terminationRequests.remove(profileID)
        records.removeAll { $0.profileID == profileID }
        preferences.previouslyRunning.remove(profileID)
        await windowService.forget(pid: previous.pid)
        await runtimeService.release(pid: previous.pid)
        await persist()
        Log.process.info("Managed instance exited; abnormal: \(crashed)")
    }

    func requestQuit() async -> Bool {
        // A read-only failed startup must never trap the user in the application.
        if loadFailed { ticker?.cancel(); return true }
        guard !isQuitting else { return false }
        isQuitting = true
        // Never exit midway through a profile launch/delete or an in-flight stop.
        for _ in 0..<48 {
            if busyProfiles.isEmpty && !metadataMutation { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard busyProfiles.isEmpty, !metadataMutation else { isQuitting = false; report(CodexMError.profileBusy); return false }
        let restoreAfterQuit = Set(instances.keys)
        preferences.previouslyRunning = restoreAfterQuit
        guard await persist() else { isQuitting = false; return false }
        if preferences.quitManagedInstances {
            for profile in profiles where !profile.isInstalledDefault && instances[profile.id] != nil { await stop(profile) }
            if profiles.contains(where: { !$0.isInstalledDefault && instances[$0.id] != nil }) {
                isQuitting = false
                if let profile = profiles.first(where: { timedOutProfiles.contains($0.id) }) { forceQuitProfile = profile }
                openDashboard(); return false
            }
        }
        preferences.previouslyRunning = restoreAfterQuit
        guard await persist() else { isQuitting = false; return false }
        ticker?.cancel()
        return true
    }
}
