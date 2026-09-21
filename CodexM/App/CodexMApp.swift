import SwiftUI
import AppKit

@main
struct CodexMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
        .commands { CodexMCommands(model: AppDelegate.model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    static let model: AppModel = {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["CODEXM_PREVIEW_ROOT"] {
            let model = AppModel(store: ProfileStore(root: URL(fileURLWithPath: root)))
            model.previewMode = true
            return model
        }
        #endif
        return AppModel()
    }()
    private var statusItem: NSStatusItem?
    private let menuPopover = NSPopover()
    private var menuRefresh: Task<Void, Never>?
    private var dashboard: NSWindow?
    private var dashboardToolbar: DashboardToolbar?
    private var settings: NSWindow?
    private var settingsToolbar: NSToolbar?
    private var handoff: NSWindow?
    private var languageObserver: NSObjectProtocol?
    private var approvedQuit = false
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let model = Self.model
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if model.previewMode, ProcessInfo.processInfo.environment["CODEXM_PREVIEW_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        #endif
        configureStatusItem()
        model.menuPanelCloser = { [weak self] in self?.menuPopover.performClose(nil) }
        model.submenuVisibilityChanged = { [weak self] visible in
            self?.menuPopover.behavior = visible ? .applicationDefined : .transient
            if !visible, !NSApp.isActive { self?.menuPopover.performClose(nil) }
        }
        model.dashboardOpener = { [weak self] in self?.showDashboard() }
        model.settingsOpener = { [weak self] in self?.showSettings() }
        model.handoffOpener = { [weak self] in self?.showHandoff() }
        languageObserver = NotificationCenter.default.addObserver(forName: Notification.Name("CodexMLanguageChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.settings?.title = L10n.text("settings.title"); self?.dashboardToolbar?.updateLabels() }
        }
        Task {
            await model.start()
            showDashboard()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if approvedQuit { return .terminateNow }
        if terminationPending { return .terminateLater }
        terminationPending = true
        Task {
            approvedQuit = await Self.model.requestQuit()
            terminationPending = false
            NSApp.reply(toApplicationShouldTerminate: approvedQuit)
        }
        return .terminateLater
    }
    @objc func showDashboard() {
        if dashboard == nil {
            dashboard = makeWindow(title: "CodexM", size: NSSize(width: 500, height: 270), view: DashboardView(model: Self.model))
            dashboardToolbar = DashboardToolbar(model: Self.model)
            dashboard?.toolbar = dashboardToolbar?.toolbar
            dashboard?.toolbarStyle = .unifiedCompact
            dashboard?.minSize = NSSize(width: 480, height: 250)
        }
        present(dashboard)
    }
    @objc func showSettings() {
        if settings == nil {
            settings = makeWindow(title: L10n.text("settings.title"), size: NSSize(width: 550, height: 600), view: SettingsView(model: Self.model))
            let toolbar = NSToolbar(identifier: "CodexM.Settings")
            toolbar.displayMode = .iconOnly
            toolbar.sizeMode = .small
            settingsToolbar = toolbar
            settings?.toolbar = toolbar
            settings?.toolbarStyle = .unifiedCompact
        }
        settings?.title = L10n.text("settings.title")
        present(settings)
    }
    func showHandoff() {
        if handoff == nil {
            handoff = makeWindow(title: Self.model.text("handoff.title"), size: NSSize(width: 728, height: 668), autosaveName: "Handoff.Independent.v1", view: HandoffView(model: Self.model, close: { [weak self] in self?.handoff?.performClose(nil) }))
            let toolbar = NSToolbar(identifier: "CodexM.Handoff")
            toolbar.displayMode = .iconOnly
            toolbar.sizeMode = .small
            handoff?.toolbar = toolbar
            handoff?.toolbarStyle = .unifiedCompact
            handoff?.minSize = NSSize(width: 728, height: 668)
            handoff?.isMovable = true
            handoff?.delegate = self
        }
        handoff?.title = Self.model.text("handoff.title")
        present(handoff)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender !== handoff || !Self.model.handoffWorking
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === handoff {
            window.contentView = nil
            handoff = nil
        }
    }
    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "CodexM")
            button.image?.size = NSSize(width: 16, height: 16)
            button.target = self; button.action = #selector(toggleMenu)
            button.toolTip = "CodexM"
        }
        menuPopover.behavior = .transient
        menuPopover.delegate = self
        let hosting = NSHostingController(rootView: MenuBarView(model: Self.model))
        hosting.sizingOptions = [.preferredContentSize]
        menuPopover.contentViewController = hosting
    }
    @objc private func toggleMenu() {
        guard let button = statusItem?.button else { return }
        if menuPopover.isShown { menuPopover.performClose(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        menuPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        menuPopover.contentViewController?.view.window?.makeKey()
        menuPopover.contentViewController?.view.window?.makeFirstResponder(nil)
    }
    func popoverDidShow(_ notification: Notification) {
        menuRefresh?.cancel()
        menuRefresh = Task {
            while !Task.isCancelled {
                Self.model.refreshAccessibility()
                await Self.model.refreshWindows()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func popoverDidClose(_ notification: Notification) { menuRefresh?.cancel(); menuRefresh = nil; ProfileMenuButton.Coordinator.closeActive() }
    private func present(_ window: NSWindow?) {
        menuPopover.performClose(nil)
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        window.attachedSheet?.makeKeyAndOrderFront(nil)
        // Popover dismissal can otherwise restore its old key window after this call.
        DispatchQueue.main.async { [weak window] in
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(nil)
            window?.attachedSheet?.makeKeyAndOrderFront(nil)
        }
    }
    private func makeWindow<V: View>(title: String, size: NSSize, autosaveName: String? = nil, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: min(size.width, 500), height: title == "CodexM" ? 250 : 400)
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false; window.center()
        window.setFrameAutosaveName(autosaveName ?? (title == "CodexM" ? "Dashboard.CompactAccounts.v2" : "Settings.CompactNative"))
        return window
    }
}
