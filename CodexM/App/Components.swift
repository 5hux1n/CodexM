import SwiftUI

struct StateBadge: View {
    let state: InstanceState
    let model: AppModel
    var body: some View {
        Label(model.text("state.\(state.rawValue)"), systemImage: state.symbol)
            .font(.caption.weight(.medium)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(state == .running ? Color.green : (state == .crashed || state == .error ? Color.orange : Color.secondary))
    }
}

struct ProfileActions: View {
    let profile: Profile
    @Bindable var model: AppModel
    var showPrimaryActions = true
    var body: some View {
        if model.state(profile) == .running {
            Button(model.text("action.focus"), systemImage: "macwindow") { Task { await model.focus(profile) } }
            if let windows = model.windows[profile.id], !windows.isEmpty {
                Divider()
                ForEach(windows) { window in
                    Button(model.windowLabel(window, in: windows)) { Task { await model.focus(profile, windowID: window.id) } }
                }
            }
            if (model.windows[profile.id] ?? []).isEmpty {
                Text(model.text(model.accessibilityGranted ? "window.empty" : "window.permissionHint"))
            }
            Divider()
            Button(model.text("action.newWindow"), systemImage: "plus.rectangle") { Task { await model.newWindow(profile) } }
            Button(model.text("action.restart"), systemImage: "arrow.clockwise") { Task { await model.stop(profile, restart: true) } }
            if showPrimaryActions { Button(model.text("action.stop"), systemImage: "stop") { Task { await model.stop(profile) } } }
            if model.timedOutProfiles.contains(profile.id) {
                Button(model.text("action.forceQuit"), role: .destructive) { model.forceQuitProfile = profile; model.openDashboard() }
            }
        } else if showPrimaryActions && !model.state(profile).isActive {
            Button(model.text("action.launch"), systemImage: "play") { Task { await model.launch(profile) } }
                .disabled(model.blockedProfiles.contains(profile.id))
        }
        Divider()
        Button(model.text("handoff.title"), systemImage: "arrow.left.arrow.right") { model.openHandoff(from: profile) }
        Button(model.text("action.edit"), systemImage: "pencil") { model.editingProfile = profile; model.openDashboard() }
        Button(model.text("action.delete"), systemImage: "trash", role: .destructive) { model.deletingProfile = profile; model.openDashboard() }
            .disabled(profile.isInstalledDefault || model.state(profile).isActive || model.blockedProfiles.contains(profile.id))
    }
}

struct NoticeView: View {
    let icon: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let actionTitle, let action { Button(actionTitle, action: action).controlSize(.small) }
            }
        }
    }
}

struct Presentations: ViewModifier {
    @Bindable var model: AppModel
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showAddProfile) { ProfileEditor(model: model, existing: nil) }
            .sheet(item: $model.editingProfile) { ProfileEditor(model: model, existing: $0) }
            .sheet(item: $model.windowPickerProfile) { profile in WindowPicker(model: model, profile: profile) }
            .alert(model.text("error.title"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button(model.text("action.ok"), role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .confirmationDialog(model.text("delete.title"), isPresented: Binding(get: { model.deletingProfile != nil }, set: { if !$0 { model.deletingProfile = nil } }), titleVisibility: .visible) {
                if let profile = model.deletingProfile {
                    Button(model.text("delete.confirm"), role: .destructive) { Task { await model.delete(profile) }; model.deletingProfile = nil }
                }
                Button(model.text("action.cancel"), role: .cancel) { model.deletingProfile = nil }
            } message: { Text(model.text("delete.message", model.deletingProfile?.name ?? "")) }
            .confirmationDialog(model.text("force.title"), isPresented: Binding(get: { model.forceQuitProfile != nil }, set: { if !$0 { model.forceQuitProfile = nil } }), titleVisibility: .visible) {
                if let profile = model.forceQuitProfile {
                    Button(model.text("action.forceQuit"), role: .destructive) { Task { await model.stop(profile, force: true) }; model.forceQuitProfile = nil }
                }
                Button(model.text("action.cancel"), role: .cancel) { model.forceQuitProfile = nil }
            } message: { Text(model.text("force.message")) }
    }
}
