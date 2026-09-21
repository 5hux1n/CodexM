import AppKit

/// Use the actual macOS title-bar toolbar, including native hover, focus and
/// window-material behavior, instead of drawing a second toolbar in the content.
@MainActor final class DashboardToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    private let model: AppModel
    let toolbar = NSToolbar(identifier: "CodexM.Dashboard")
    private let add = NSToolbarItem.Identifier("CodexM.AddProfile")
    private let handoff = NSToolbarItem.Identifier("CodexM.Handoff")
    private let settings = NSToolbarItem.Identifier("CodexM.Settings")

    init(model: AppModel) {
        self.model = model
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, handoff, settings, add] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, handoff, settings, add] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == add || identifier == settings || identifier == handoff else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let asset = identifier == add ? "NavAdd" : identifier == handoff ? "NavHandoff" : "NavSettings"
        if let image = NSImage(named: asset)?.copy() as? NSImage {
            image.size = NSSize(width: 14, height: 14); image.isTemplate = true
            item.image = image
        }
        item.target = self
        item.action = identifier == add ? #selector(addProfile) : identifier == handoff ? #selector(openHandoff) : #selector(openSettings)
        let button = NSButton(image: item.image ?? NSImage(), target: self, action: item.action)
        button.isBordered = true
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = false
        button.focusRingType = .none
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        item.view = button
        configure(item)
        return item
    }
    func updateLabels() { toolbar.items.forEach(configure) }
    private func configure(_ item: NSToolbarItem) {
        guard item.itemIdentifier == add || item.itemIdentifier == settings || item.itemIdentifier == handoff else { return }
        item.label = model.text(item.itemIdentifier == add ? "profile.add" : item.itemIdentifier == handoff ? "handoff.title" : "settings.title")
        if let button = item.view as? NSButton {
            button.setAccessibilityLabel(item.label)
            button.toolTip = item.label
            button.isEnabled = validateToolbarItem(item)
        }
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { item.itemIdentifier == settings || (model.ready && !model.isQuitting) }
    @objc private func openHandoff() { model.openHandoff() }
    @objc private func addProfile() { model.showAddProfile = true; model.openDashboard() }
    @objc private func openSettings() { model.openSettings() }
}
