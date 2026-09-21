import SwiftUI
import AppKit

/// SwiftUI owns the arrow anchor. AppKit owns the submenu so hover tracking
/// remains reliable while the status-bar popover is not the active window.
struct ProfileMenuButton: NSViewRepresentable {
    let profile: Profile
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(profile: profile, model: model) }

    func makeNSView(context: Context) -> ProfileArrowButton {
        let button = ProfileArrowButton(frame: .zero)
        button.profileID = profile.id
        button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        button.image?.size = NSSize(width: 10, height: 10)
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.open(_:))
        button.onHover = { [weak coordinator = context.coordinator, weak button] inside in
            if let button { coordinator?.arrowHover(button, inside: inside) }
        }
        return button
    }

    func updateNSView(_ button: ProfileArrowButton, context: Context) {
        context.coordinator.update(profile: profile, sender: button)
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(model.text("action.more") + " · " + profile.name)
    }

    static func dismantleNSView(_ button: ProfileArrowButton, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        enum State { case closed, hovering, pinned }

        private(set) var state: State = .closed
        private var profile: Profile
        private let model: AppModel
        private static weak var active: Coordinator?
        private weak var arrow: ProfileArrowButton?
        private var openProfileID: UUID?
        private var popover: NSPopover?
        private var content: NSView?
        private var outsideMonitor: Any?
        private var localMonitor: Any?
        private var pointerTimer: Timer?
        private var leftAt: Date?
        private var hoveredWindow: UUID?
        private var previewTask: Task<Void, Never>?
        private var errorLabel: NSTextField?

        private lazy var dwell = MenuArrowDwell { [weak self] in
            guard let self, let arrow = self.arrow, arrow.isEnabled,
                  arrow.profileID == self.profile.id,
                  self.state == .closed, Self.active?.state != .pinned else { return }
            self.show(arrow, pinned: false)
        }

        private lazy var preview = WindowHoverPreview { [weak self] windowID in
            guard let self, self.hoveredWindow == windowID,
                  let profileID = self.openProfileID,
                  let profile = self.currentProfile(id: profileID) else { return }
            self.previewTask = self.model.previewWindow(profile, windowID: windowID) { [weak self] error in
                self?.presentError(error)
            }
        }

        init(profile: Profile, model: AppModel) {
            self.profile = profile
            self.model = model
        }

        func update(profile: Profile, sender: ProfileArrowButton) {
            if self.profile.id != profile.id, state != .closed {
                close()
            }
            self.profile = profile
            sender.profileID = profile.id
        }

        func arrowHover(_ sender: ProfileArrowButton, inside: Bool) {
            guard sender.profileID == profile.id else { return }
            arrow = sender
            if state == .closed {
                dwell.setInside(inside && sender.isEnabled && Self.active?.state != .pinned)
            }
            if inside { leftAt = nil }
        }

        @objc func open(_ sender: ProfileArrowButton) {
            guard sender.profileID == profile.id else { return }
            dwell.setInside(false)
            switch state {
            case .closed:
                show(sender, pinned: true)
            case .hovering:
                state = .pinned
                leftAt = nil
            case .pinned:
                close()
            }
        }

        private func show(_ sender: ProfileArrowButton, pinned: Bool) {
            guard sender.window != nil,
                  sender.profileID == profile.id,
                  let openingProfile = currentProfile(id: profile.id) else { return }

            Self.active?.close()
            Self.active = self
            arrow = sender
            openProfileID = openingProfile.id
            state = pinned ? .pinned : .hovering
            model.refreshAccessibility()

            let view = buildMenu(for: openingProfile)
            let controller = NSViewController()
            controller.view = view

            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.delegate = self
            popover.contentViewController = controller
            popover.contentSize = view.frame.size
            self.popover = popover
            content = view

            model.submenuVisibilityChanged?(true)
            popover.show(relativeTo: sender.bounds.insetBy(dx: -1, dy: 0), of: sender, preferredEdge: .maxX)
            guard let window = view.window else { close(); return }
            window.level = .popUpMenu
            window.hidesOnDeactivate = false
            window.makeFirstResponder(nil)

            if let parentWindow = sender.window {
                let opensRight = window.frame.midX >= parentWindow.frame.midX
                sender.image = NSImage(systemSymbolName: opensRight ? "chevron.right" : "chevron.left", accessibilityDescription: nil)
            }

            installMonitors()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.samplePointer(NSEvent.mouseLocation, now: Date()) }
            }
            pointerTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }

        /// The arrow, the popover and the small gap between them form one hover region.
        func samplePointer(_ point: CGPoint, now: Date) {
            guard state != .closed else { return }
            guard let window = content?.window, window.isVisible else { close(); return }
            let anchor = arrow.flatMap { button in
                button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
            }
            let panel = window.frame
            var inside = panel.contains(point) || anchor?.insetBy(dx: -3, dy: -3).contains(point) == true
            if let anchor {
                let bridge = CGRect(
                    x: min(anchor.minX, panel.minX),
                    y: min(anchor.minY, panel.minY) - 3,
                    width: max(anchor.maxX, panel.maxX) - min(anchor.minX, panel.minX),
                    height: max(anchor.maxY, panel.maxY) - min(anchor.minY, panel.minY) + 6
                )
                inside = inside || bridge.contains(point)
            }
            if inside {
                leftAt = nil
            } else if state == .hovering {
                if let leftAt, now.timeIntervalSince(leftAt) >= 0.3 { close() }
                else if leftAt == nil { leftAt = now }
            }
        }

        private func buildMenu(for profile: Profile) -> NSView {
            let profileID = profile.id
            let menuWidth: CGFloat = 232
            let edgeInset: CGFloat = 6
            let rowWidth = menuWidth - edgeInset * 2
            let titleInset: CGFloat = 22
            var entries: [(view: NSView, height: CGFloat, x: CGFloat, width: CGFloat)] = []

            func row(
                _ title: String,
                enabled: Bool = true,
                checked: Bool = false,
                windowID: UUID? = nil,
                action: @escaping @MainActor (Profile) -> Void
            ) {
                let button = MenuRowButton(frame: .zero)
                button.title = title
                button.isEnabled = enabled
                button.checked = checked
                button.invoke = { [weak self] in
                    guard let self, self.openProfileID == profileID,
                          let current = self.currentProfile(id: profileID) else { return }
                    self.close()
                    action(current)
                }
                button.onHover = { [weak self] inside in
                    guard let self, self.openProfileID == profileID else { return }
                    if inside { self.selectWindow(windowID) }
                    else if let windowID, self.hoveredWindow == windowID { self.selectWindow(nil) }
                }
                entries.append((button, 24, edgeInset, rowWidth))
            }

            func separator() {
                let box = NSBox()
                box.boxType = .separator
                entries.append((box, 7, edgeInset + 4, rowWidth - 8))
            }

            if model.state(profile) == .running {
                row(model.text("action.focus")) { [weak model] profile in
                    Task { await model?.focus(profile) }
                }

                let windows = model.windows[profileID] ?? []
                if !windows.isEmpty {
                    separator()

                    let hintX = edgeInset + titleInset
                    let hint: NSView
                    if model.accessibilityGranted {
                        let label = NSTextField(labelWithString: model.text("window.hoverHint"))
                        label.font = .systemFont(ofSize: 11)
                        label.textColor = .secondaryLabelColor
                        label.lineBreakMode = .byTruncatingTail
                        label.maximumNumberOfLines = 1
                        hint = label
                    } else {
                        hint = accessibilityPermissionHint()
                    }
                    entries.append((hint, 22, hintX, menuWidth - hintX - edgeInset))

                    let documentHeight = CGFloat(windows.count) * 24
                    let document = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: documentHeight))
                    for (index, window) in windows.enumerated() {
                        let button = MenuRowButton(frame: NSRect(
                            x: 0,
                            y: CGFloat(windows.count - index - 1) * 24,
                            width: rowWidth,
                            height: 24
                        ))
                        button.title = model.windowLabel(window, in: windows)
                        button.checked = window.isFocused
                        button.invoke = { [weak self] in
                            guard let self, self.openProfileID == profileID,
                                  let current = self.currentProfile(id: profileID) else { return }
                            self.close()
                            Task { await self.model.focus(current, windowID: window.id) }
                        }
                        button.onHover = { [weak self] inside in
                            guard let self, self.openProfileID == profileID, self.model.accessibilityGranted else { return }
                            if inside { self.selectWindow(window.id) }
                            else if self.hoveredWindow == window.id { self.selectWindow(nil) }
                        }
                        document.addSubview(button)
                    }

                    let scroll = NSScrollView()
                    scroll.drawsBackground = false
                    scroll.hasVerticalScroller = windows.count > 10
                    scroll.autohidesScrollers = true
                    scroll.documentView = document
                    entries.append((scroll, min(240, documentHeight), edgeInset, rowWidth))
                }

                separator()
                row(model.text("action.newWindow")) { [weak model] profile in
                    Task { await model?.newWindow(profile) }
                }
                row(model.text("action.restart")) { [weak model] profile in
                    Task { await model?.stop(profile, restart: true) }
                }
                if model.timedOutProfiles.contains(profileID) {
                    row(model.text("action.forceQuit")) { [weak model] profile in
                        model?.forceQuitProfile = profile
                        model?.openDashboard()
                    }
                }
                separator()
            }

            row(model.text("handoff.title")) { [weak model] profile in model?.openHandoff(from: profile) }
            row(model.text("action.edit")) { [weak model] profile in
                model?.editingProfile = profile
                model?.openDashboard()
            }
            row(
                model.text("action.delete"),
                enabled: !profile.isInstalledDefault && !model.state(profile).isActive && !model.blockedProfiles.contains(profileID)
            ) { [weak model] profile in
                model?.deletingProfile = profile
                model?.openDashboard()
            }

            let menuHeight = entries.reduce(CGFloat(12)) { $0 + $1.height }
            let view = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: menuHeight))
            var y = menuHeight - 6
            for entry in entries {
                y -= entry.height
                entry.view.frame = NSRect(x: entry.x, y: y, width: entry.width, height: entry.height)
                view.addSubview(entry.view)
                if let scroll = entry.view as? NSScrollView, let document = scroll.documentView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - entry.height)))
                }
            }

            let error = NSTextField(wrappingLabelWithString: "")
            error.font = .systemFont(ofSize: 11)
            error.textColor = .systemRed
            error.isHidden = true
            error.frame = NSRect(x: edgeInset + titleInset, y: 6, width: menuWidth - edgeInset * 2 - titleInset, height: 40)
            errorLabel = error
            return view
        }

        private func currentProfile(id: UUID) -> Profile? {
            model.profiles.first { $0.id == id }
        }

        private func accessibilityPermissionHint() -> NSView {
            let prefix = NSTextField(labelWithString: model.text("window.focusPermissionPrefix"))
            prefix.font = .systemFont(ofSize: 11)
            prefix.textColor = .secondaryLabelColor
            prefix.setContentCompressionResistancePriority(.required, for: .horizontal)

            let link = MenuLinkButton(frame: .zero)
            link.attributedTitle = NSAttributedString(
                string: model.text("accessibility.authorization"),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            link.invoke = { [weak model] in model?.requestAccessibility() }
            link.setAccessibilityLabel(model.text("accessibility.request"))
            link.setContentCompressionResistancePriority(.required, for: .horizontal)

            let stack = NSStackView(views: [prefix, link])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 0
            return stack
        }

        private func presentError(_ message: String) {
            model.refreshAccessibility()
            guard model.accessibilityGranted else { return }
            guard let view = content, let label = errorLabel else { return }
            if label.superview == nil {
                let addedHeight: CGFloat = 40
                for child in view.subviews {
                    child.setFrameOrigin(CGPoint(x: child.frame.minX, y: child.frame.minY + addedHeight))
                }
                view.setFrameSize(NSSize(width: view.frame.width, height: view.frame.height + addedHeight))
                view.addSubview(label)
                popover?.contentSize = view.frame.size
            }
            label.stringValue = message
            label.isHidden = false
        }

        private func selectWindow(_ id: UUID?) {
            guard hoveredWindow != id else { return }
            preview.cancel()
            previewTask?.cancel()
            previewTask = nil
            model.windowHighlight.hide()
            hoveredWindow = id
            if let id { preview.highlight(id) }
        }

        private func installMonitors() {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if event.type != .keyDown || event.keyCode == 53 { self?.close() }
                }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    if event.type == .keyDown, event.keyCode == 53 {
                        self.close()
                        return true
                    }
                    if event.type != .keyDown, event.window !== self.content?.window {
                        let onArrow = self.arrow.map {
                            event.window === $0.window && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                        } ?? false
                        if !onArrow { self.close() }
                    }
                    return false
                }
                return consumed ? nil : event
            }
        }

        func popoverDidClose(_ notification: Notification) { close() }
        static func closeActive() { active?.close() }

        func close() {
            guard state != .closed || popover != nil else {
                dwell.setInside(false)
                return
            }
            state = .closed
            dwell.setInside(false)
            leftAt = nil
            pointerTimer?.invalidate()
            pointerTimer = nil
            selectWindow(nil)
            openProfileID = nil
            arrow?.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)

            let previous = popover
            popover = nil
            previous?.delegate = nil
            previous?.performClose(nil)
            content = nil
            errorLabel = nil

            if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
            outsideMonitor = nil
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            localMonitor = nil
            if Self.active === self {
                Self.active = nil
                model.submenuVisibilityChanged?(false)
            }
        }
    }
}

/// A single weak registry samples arrows and rows even when their windows are inactive.
@MainActor final class MenuPointerTracker {
    static let shared = MenuPointerTracker()
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    private let buttons = NSHashTable<MenuTrackingButton>.weakObjects()
    private var timer: Timer?

    func add(_ button: MenuTrackingButton) {
        buttons.add(button)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.sample(at: self.pointerLocation()) } }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func sample(at point: CGPoint) {
        let current = buttons.allObjects
        if current.isEmpty {
            timer?.invalidate()
            timer = nil
        }
        for button in current { button.sample(at: point) }
    }
}

@MainActor class MenuTrackingButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private(set) var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        focusRingType = .none
        refusesFirstResponder = true
        font = .systemFont(ofSize: 13)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { MenuPointerTracker.shared.add(self) }
        else { updateHover(false) }
    }

    func sample(at point: CGPoint) {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, isEnabled else {
            updateHover(false)
            return
        }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        updateHover(bounds.intersection(visibleRect).contains(local))
    }

    func updateHover(_ inside: Bool) {
        guard hovered != inside else { return }
        hovered = inside
        isHighlighted = inside
        needsDisplay = true
        onHover?(inside)
    }
}

@MainActor final class ProfileArrowButton: MenuTrackingButton {
    var profileID: UUID?
}

@MainActor final class MenuRowButton: MenuTrackingButton {
    var checked = false { didSet { updateStateImage() } }
    var invoke: (@MainActor () -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = true
        bezelStyle = .accessoryBarAction
        showsBorderOnlyWhileMouseInside = true
        target = self
        action = #selector(invokeAction)
        alignment = .left
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        cell?.lineBreakMode = .byTruncatingMiddle
        updateStateImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    @objc private func invokeAction() {
        if isEnabled { invoke?() }
    }

    private func updateStateImage() {
        image = checked
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            : NSImage(size: NSSize(width: 14, height: 14))
        image?.size = NSSize(width: 14, height: 14)
    }
}

@MainActor final class MenuLinkButton: NSButton {
    var invoke: (@MainActor () -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        focusRingType = .none
        refusesFirstResponder = true
        target = self
        action = #selector(invokeAction)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func invokeAction() { invoke?() }
}

@MainActor final class MenuArrowDwell: NSObject {
    private var timer: Timer?
    private var inside = false
    private let delay: TimeInterval
    private let open: () -> Void

    init(delay: TimeInterval = 0.18, open: @escaping () -> Void) {
        self.delay = delay
        self.open = open
    }

    func setInside(_ value: Bool) {
        guard value != inside else { return }
        inside = value
        timer?.invalidate()
        timer = nil
        guard value else { return }
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(fire), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    @objc private func fire() {
        timer = nil
        if inside { open() }
    }
}

/// Dwell rather than immediate activation; leaving a row or closing cancels it.
@MainActor final class WindowHoverPreview: NSObject {
    private var timer: Timer?
    private var windowID: UUID?
    private let delay: TimeInterval
    private let preview: (UUID) -> Void

    init(delay: TimeInterval = 0.4, preview: @escaping (UUID) -> Void) {
        self.delay = delay
        self.preview = preview
    }

    func highlight(_ id: UUID) {
        cancel()
        windowID = id
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(fire), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        windowID = nil
    }

    @objc private func fire() {
        let id = windowID
        cancel()
        if let id { preview(id) }
    }
}
