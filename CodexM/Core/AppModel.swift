import AppKit
import Observation
import ApplicationServices
import ServiceManagement

@MainActor @Observable
final class AppModel {
    var profiles: [Profile] = []
    var preferences = Preferences()
    var runtime: RuntimeInfo?
    var instances: [UUID: CodexInstance] = [:]
    var states: [UUID: InstanceState] = [:]
    var windows: [UUID: [CodexWindow]] = [:]
    var lastWindows: [UUID: UUID] = [:]
    var authStates: [UUID: AuthState] = [:]
    var externalInstances: [ProcessIdentity] = []
    var pendingLogins: [UUID: PendingLogin] = [:]
    var blockedProfiles: Set<UUID> = []
    var busyProfiles: Set<UUID> = []
    var timedOutProfiles: Set<UUID> = []
    var accessibilityGranted = AXIsProcessTrusted()
    var previewMode = false
    var ready = false
    var loadFailed = false
    var storageError = false
    var errorMessage: String?
    var editingProfile: Profile?
    var showAddProfile = false
    var handoffWorking = false
    var windowNotes: [UUID: String] = [:]
    var handoffSourceID: UUID?
    var deletingProfile: Profile?
    var forceQuitProfile: Profile?
    var windowPickerProfile: Profile?
    var loginItemEnabled = SMAppService.mainApp.status == .enabled
    var loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    var isQuitting = false
    var relocatingAccounts = false

    @ObservationIgnored let nativeMigration = NativeMigrationCoordinator()
    @ObservationIgnored let handoffCoordinator = HandoffCoordinator()
    @ObservationIgnored let handoffStore: HandoffStore
    @ObservationIgnored let store: ProfileStore
    @ObservationIgnored let runtimeService: RuntimeService
    @ObservationIgnored let windowService = WindowService()
    @ObservationIgnored let windowHighlight = WindowHighlight()
    @ObservationIgnored let authMonitor = AuthMonitor()
    @ObservationIgnored var records: [RuntimeRecord] = []
    @ObservationIgnored var authMetadata: [UUID: AuthMetadata] = [:]
    @ObservationIgnored var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored var ticker: Task<Void, Never>?
    @ObservationIgnored var refreshing = false
    @ObservationIgnored var windowsRefreshing = false
    @ObservationIgnored var persisting = false
    @ObservationIgnored var needsSave = false
    @ObservationIgnored var metadataMutation = false
    @ObservationIgnored var focusRequestSerial: UInt64 = 0
    @ObservationIgnored var terminationRequests: Set<UUID> = []
    @ObservationIgnored var menuPanelCloser: (() -> Void)?
    @ObservationIgnored var submenuVisibilityChanged: ((Bool) -> Void)?
    @ObservationIgnored var dashboardOpener: (() -> Void)?
    @ObservationIgnored var settingsOpener: (() -> Void)?
    @ObservationIgnored var handoffOpener: (() -> Void)?

    init(store: ProfileStore = ProfileStore(), runtimeService: RuntimeService = RuntimeService()) { self.store = store; self.runtimeService = runtimeService; self.handoffStore = HandoffStore(root: store.root) }
    var dataRoot: URL { store.root }
    var compatibilityChanged: Bool { runtime.map { preferences.acknowledgedRuntimeVersion != nil && preferences.acknowledgedRuntimeVersion != $0.fingerprint } ?? false }
    var runningCount: Int { instances.values.filter { $0.state.isActive }.count }
    func state(_ profile: Profile) -> InstanceState { states[profile.id] ?? .stopped }
    func text(_ key: String, _ arguments: CVarArg...) -> String {
        _ = preferences.language
        let value = L10n.text(key)
        return arguments.isEmpty ? value : String(format: value, locale: Locale.current, arguments: arguments)
    }
    func report(_ error: Error) {
        errorMessage = (error as? NativeMigrationDiagnostic)?.errorDescription ?? (error as? NativeMigrationError)?.errorDescription ?? (error as? CodexMError)?.errorDescription ?? CodexMError.unavailable.errorDescription
        Log.ui.error("An operation could not be completed")
        openDashboard()
    }
    func openDashboard() { menuPanelCloser?(); dashboardOpener?() }
    func openSettings() { menuPanelCloser?(); settingsOpener?() }

    func start() async {
        guard !ready, !loadFailed else { return }
        do {
            let stored = try await store.load()
            profiles = stored.profiles; preferences = stored.preferences; records = stored.runtimeRecords
            L10n.setLanguage(preferences.language)
            await detectRuntime()
            installObservation()
            await refresh()
            ready = true
            for profile in profiles where !profile.isInstalledDefault && profile.launchOnStartup {
                if instances[profile.id] == nil { await launch(profile) }
            }
            await persist()
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    await self.refresh()
                }
            }
        } catch { loadFailed = true; report(error) }
    }

    func detectRuntime() async {
        let discovered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let detected = await runtimeService.detect(preferred: preferences.selectedRuntimePath, discovered: discovered)
        if detected != runtime {
            Log.runtime.info("Runtime availability or version changed")
            if let runtime, let detected, runtime.fingerprint != detected.fingerprint { Log.compatibility.notice("Official runtime version changed; human compatibility check recommended") }
        }
        runtime = detected
        if runtime != nil, !profiles.contains(where: \.isInstalledDefault), !previewMode {
            profiles.insert(.installedDefault(name: text("account.default")), at: 0)
            if ready { await persist() }
        }
        if preferences.acknowledgedRuntimeVersion == nil, let runtime { preferences.acknowledgedRuntimeVersion = runtime.fingerprint }
    }

    func installObservation() {
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibility(); await self?.refreshWindows() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: .codexWindowsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshWindows() }
        })
    }

    /// Coalescing persistence always writes the latest complete snapshot. Views
    /// cannot race two partial preference/profile documents into lost updates.
    @discardableResult func persist() async -> Bool {
        needsSave = true
        while persisting { try? await Task.sleep(for: .milliseconds(20)) }
        persisting = true
        defer { persisting = false }
        while needsSave {
            needsSave = false
            let snapshot = StoredState(profiles: profiles, preferences: preferences, runtimeRecords: records)
            do { try await store.save(snapshot); storageError = false }
            catch { storageError = true; report(error); return false }
        }
        return true
    }
    func updatePreferences(_ change: (inout Preferences) -> Void) {
        guard !relocatingAccounts else { return }
        change(&preferences); L10n.setLanguage(preferences.language)
        NotificationCenter.default.post(name: Notification.Name("CodexMLanguageChanged"), object: nil)
        Task { await persist() }
    }
    func acknowledgeCompatibility() {
        updatePreferences { $0.acknowledgedRuntimeVersion = runtime?.fingerprint }
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }
    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func setLoginItem(_ enabled: Bool) async {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
        } catch { report(CodexMError.loginItemFailed) }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func locateRuntime() async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false; panel.prompt = text("runtime.locate")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await selectRuntime(url)
        } catch { report(error) }
    }
    func selectRuntime(_ url: URL) async throws {
        let inspected = try await runtimeService.inspect(url)
        runtime = inspected
        preferences.selectedRuntimePath = url.path
        await detectRuntime()
        await persist()
    }

}
