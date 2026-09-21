import SwiftUI
import AppKit

struct CodexMCommands: Commands {
    @Bindable var model: AppModel
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(model.text("menu.open")) { model.openDashboard() }.keyboardShortcut("0")
        }
        CommandGroup(replacing: .appSettings) {
            Button(model.text("settings.title")) { model.openSettings() }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .appTermination) {
            Button(model.text("app.quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        CommandGroup(replacing: .newItem) {
            Button(model.text("handoff.title")) { model.openHandoff() }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!model.ready)
            Button(model.text("profile.add")) { model.showAddProfile = true; model.openDashboard() }.keyboardShortcut("n").disabled(!model.ready)
            Button(model.text("action.close")) { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.text("edit.undo")) { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }.keyboardShortcut("z")
        }
        CommandGroup(replacing: .pasteboard) {
            Button(model.text("edit.cut")) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.keyboardShortcut("x")
            Button(model.text("edit.copy")) { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }.keyboardShortcut("c")
            Button(model.text("edit.paste")) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }.keyboardShortcut("v")
            Button(model.text("edit.selectAll")) { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }.keyboardShortcut("a")
        }
    }
}
