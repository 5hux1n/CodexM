import SwiftUI

struct ProfileEditor: View {
    @Bindable var model: AppModel
    let existing: Profile?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var launchOnStartup = false
    @State private var restoreOnLaunch = true
    @State private var saving = false
    @State private var validation: String?
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.text(existing == nil ? "profile.add" : "profile.edit")).font(.title2.bold())
            TextField(model.text("profile.name"), text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                .onSubmit { save() }
            Text(model.text("profile.nameHint")).font(.caption).foregroundStyle(.secondary)
            if existing?.isInstalledDefault != true {
            Toggle(model.text("profile.autoLaunch"), isOn: $launchOnStartup)
            } else { Text(model.text("account.defaultHint")).font(.caption).foregroundStyle(.secondary) }
            if let validation { Text(validation).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(model.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.text("action.save")) { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
        }.padding(26).frame(width: 420)
            .onAppear { name = existing?.name ?? ""; launchOnStartup = existing?.launchOnStartup ?? false; restoreOnLaunch = existing?.restoreOnLaunch ?? true; nameFocused = true }
            .interactiveDismissDisabled(saving)
    }
    private func save() {
        guard !saving else { return }
        do { _ = try Profile.validatedName(name) } catch { validation = error.localizedDescription; return }
        saving = true
        Task {
            if await model.saveProfile(existing: existing, name: name, launchOnStartup: launchOnStartup, restoreOnLaunch: restoreOnLaunch) { dismiss() }
            else { validation = model.errorMessage; model.errorMessage = nil }
            saving = false
        }
    }
}

struct WindowPicker: View {
    @Bindable var model: AppModel
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile.name).font(.title2.bold())
            Text(model.text("window.noteHint")).font(.caption).foregroundStyle(.secondary)
            if !model.accessibilityGranted { Text(model.text("accessibility.explanation")) }
            else if (model.windows[profile.id] ?? []).isEmpty { Text(model.text("window.empty")).foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.windows[profile.id] ?? []) { window in
                        VStack(alignment: .leading, spacing: 5) {
                            Button { Task { await model.focus(profile, windowID: window.id) }; dismiss() } label: {
                                Label(model.windowLabel(window, in: model.windows[profile.id] ?? []), systemImage: window.isMinimized ? "minus.rectangle" : "macwindow")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.buttonStyle(.bordered).focusEffectDisabled()
                            TextField(model.text("window.note"), text: Binding(get: { model.windowNotes[window.id] ?? "" }, set: { model.windowNotes[window.id] = String($0.prefix(80)) }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }.frame(maxHeight: 280)
            HStack {
                Button(model.text("action.newWindow")) { Task { await model.newWindow(profile) } }
                Spacer()
                Button(model.text("action.done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 440)
        .task {
            while !Task.isCancelled {
                await model.refreshWindows()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
