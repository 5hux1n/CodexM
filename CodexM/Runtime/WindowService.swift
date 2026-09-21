import AppKit
import ApplicationServices

private func windowNotification(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    NotificationCenter.default.post(name: .codexWindowsChanged, object: nil)
}
extension Notification.Name { static let codexWindowsChanged = Notification.Name("dev.codexm.windowsChanged") }

/// AX IPC is confined to this actor, away from the UI thread. Window IDs are
/// stable across enumeration by CFEqual, never by title or list position.
actor WindowService {
    private struct Entry { let id: UUID; let element: AXUIElement }
    private var entries: [Int32: [Entry]] = [:]
    private var fallbackIDs: [Int32: [UInt32: UUID]] = [:]
    private var observers: [Int32: AXObserver] = [:]

    func observe(pid: Int32) {
        guard AXIsProcessTrusted(), observers[pid] == nil else { return }
        var candidate: AXObserver?
        guard AXObserverCreate(pid, windowNotification, &candidate) == .success, let observer = candidate else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        for event in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification] {
            AXObserverAddNotification(observer, app, event as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    func forget(pid: Int32) {
        if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        entries.removeValue(forKey: pid)
        fallbackIDs.removeValue(forKey: pid)
    }

    func enumerate(identity: ProcessIdentity) -> [CodexWindow] {
        guard ProcessProbe.matches(identity) else { return [] }
        guard AXIsProcessTrusted() else { return enumerateSystemWindows(pid: identity.pid) }
        let pid = identity.pid
        observe(pid: pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            entries[pid] = []
            return enumerateSystemWindows(pid: pid)
        }
        let focused = attribute(app, kAXFocusedWindowAttribute)
        let cg = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = cg.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
        let old = entries[pid] ?? []
        var fresh: [Entry] = []
        var result: [CodexWindow] = []
        for window in windows {
            let number = matchingWindowNumber(window, candidates: owned)
            let entry: Entry
            if let existing = old.first(where: { CFEqual($0.element, window) }) {
                entry = existing
            } else {
                entry = Entry(id: number.flatMap { fallbackIDs[pid]?[$0] } ?? UUID(), element: window)
            }
            fresh.append(entry)
            let axTitle = attribute(window, kAXTitleAttribute) as? String ?? ""
            let minimized = attribute(window, kAXMinimizedAttribute) as? Bool ?? false
            let cgTitle = number.flatMap { number in owned.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number }?[kCGWindowName as String] as? String } ?? ""
            let title = axTitle.isEmpty ? cgTitle : axTitle
            result.append(CodexWindow(id: entry.id, pid: pid, title: title, number: number, isMinimized: minimized, isFocused: focused.map { CFEqual($0, window) } ?? false))
            if let observer = observers[pid], !old.contains(where: { $0.id == entry.id }) {
                for event in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                    AXObserverAddNotification(observer, window, event as CFString, nil)
                }
            }
        }
        if old.count != fresh.count { Log.window.debug("Managed window count changed to \(fresh.count)") }
        entries[pid] = fresh
        fallbackIDs[pid] = Dictionary(result.compactMap { window in window.number.map { ($0, window.id) } }, uniquingKeysWith: { first, _ in first })
        return result
    }

    // WindowServer metadata is a fallback only; missing titles remain untitled.
    // Never invent a window from a running process, or request screen recording.
    private func enumerateSystemWindows(pid: Int32) -> [CodexWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var ids: [UInt32: UUID] = [:]
        let result = list.compactMap { info -> CodexWindow? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 80, rect.height > 80 else { return nil }
            let id = fallbackIDs[pid]?[number] ?? UUID()
            ids[number] = id
            return CodexWindow(id: id, pid: pid, title: info[kCGWindowName as String] as? String ?? "", number: number, isMinimized: false, isFocused: false)
        }
        fallbackIDs[pid] = ids
        return result
    }

    @discardableResult func raise(identity: ProcessIdentity, windowID: UUID?, allowFallback: Bool = false) throws -> UUID {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw CodexMError.accessibilityDenied }
        guard ProcessProbe.matches(identity) else { throw CodexMError.processChanged }
        _ = enumerate(identity: identity)
        let list = entries[identity.pid] ?? []
        let app = AXUIElementCreateApplication(identity.pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        let focused = attribute(app, kAXFocusedWindowAttribute)
        let selected = windowID.flatMap { id in list.first { $0.id == id } } ?? (windowID == nil || allowFallback ? (list.first { entry in focused.map { CFEqual($0, entry.element) } == true } ?? list.first) : nil)
        guard let window = selected else { throw CodexMError.windowNotFound }
        if (attribute(window.element, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        try Task.checkCancellation()
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        // AXFocusedWindow belongs to the application. AXFocused on a window is
        // not a reliable substitute, especially with multiple instances.
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window.element)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) == .success else { throw CodexMError.windowNotFound }
        return window.id
    }

    func focusedFrame(identity: ProcessIdentity, windowID: UUID) -> CGRect? {
        guard !Task.isCancelled, ProcessProbe.matches(identity),
              let window = entries[identity.pid]?.first(where: { $0.id == windowID }) else { return nil }
        let app = AXUIElementCreateApplication(identity.pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard (attribute(app, kAXFrontmostAttribute) as? Bool) == true,
              let focused = attribute(app, kAXFocusedWindowAttribute), CFEqual(focused, window.element),
              let position = attribute(window.element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window.element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// Invoke an actual enabled official menu item; never synthesize a second process.
    func newWindow(identity: ProcessIdentity) throws {
        guard AXIsProcessTrusted() else { throw CodexMError.accessibilityDenied }
        guard ProcessProbe.matches(identity) else { throw CodexMError.processChanged }
        let app = AXUIElementCreateApplication(identity.pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { throw CodexMError.newWindowUnavailable }
        let names: Set<String> = ["New Window", "新建窗口", "新窗口", "新增視窗", "新建視窗"]
        var budget = 160
        guard let item = findMenuItem(unsafeDowncast(bar, to: AXUIElement.self), titles: names, depth: 0, budget: &budget),
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { throw CodexMError.newWindowUnavailable }
    }

    private func findMenuItem(_ element: AXUIElement, titles: Set<String>, depth: Int, budget: inout Int) -> AXUIElement? {
        guard depth < 5, budget > 0 else { return nil }; budget -= 1
        if let title = attribute(element, kAXTitleAttribute) as? String, titles.contains(title),
           (attribute(element, kAXEnabledAttribute) as? Bool) == true { return element }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let result = findMenuItem(child, titles: titles, depth: depth + 1, budget: &budget) { return result }
        }
        return nil
    }
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private func matchingWindowNumber(_ window: AXUIElement, candidates: [[String: Any]]) -> UInt32? {
        guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let matches = candidates.filter { candidate in
            guard let dictionary = candidate[kCGWindowBounds as String] as? [String: Any], let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
            return abs(bounds.minX - point.x) < 2 && abs(bounds.minY - point.y) < 2 && abs(bounds.width - dimensions.width) < 2 && abs(bounds.height - dimensions.height) < 2
        }
        // CG numbers are display metadata only. Ambiguous geometry is never identity.
        guard matches.count == 1 else { return nil }
        return (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }
}
