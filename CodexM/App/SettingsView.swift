import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var dropTargeted = false
    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section(model.text("settings.general")) {
                Toggle(model.text("settings.login"), isOn: Binding(get: { model.loginItemEnabled }, set: { enabled in Task { await model.setLoginItem(enabled) } }))
                if model.loginItemNeedsApproval {
                    Button(model.text("settings.loginApproval")) { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle(model.text("settings.quitInstances"), isOn: preference(\.quitManagedInstances))
                Text(model.text("settings.quitHint")).font(.caption).foregroundStyle(.secondary)
                Picker(model.text("settings.language"), selection: preference(\.language)) {
                    Text(model.text("language.system")).tag(AppLanguage.system)
                    Text(model.text("language.en")).tag(AppLanguage.en)
                    Text(model.text("language.zhHans")).tag(AppLanguage.zhHans)
                }
            }.disabled(!model.ready)
            Section(model.text("settings.runtime")) {
                Text(model.text("runtime.dropHint")).font(.caption).foregroundStyle(.secondary)
                LabeledContent(model.text("runtime.version"), value: model.runtime?.fingerprint ?? model.text("runtime.missing"))
                if let runtime = model.runtime {
                    LabeledContent(model.text("runtime.path")) { Text(runtime.appURL.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
                }
                HStack {
                    Button(model.text("runtime.locate")) { Task { await model.locateRuntime() } }
                    Button(model.text("runtime.detect")) { Task { await model.detectRuntime() } }
                }
                if model.compatibilityChanged {
                    Text(model.text("runtime.updated")).font(.caption).foregroundStyle(.secondary)
                    Button(model.text("action.dismiss")) { model.acknowledgeCompatibility() }
                }
            }
            Section(model.text("accessibility.title")) {
                Label(model.text(model.accessibilityGranted ? "accessibility.granted" : "accessibility.missing"), systemImage: model.accessibilityGranted ? "checkmark.shield" : "hand.raised")
                Text(model.text("accessibility.explanation")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.text("accessibility.refresh")) { model.refreshAccessibility(); Task { await model.refreshWindows() } }
                    Button(model.text("accessibility.request")) { model.requestAccessibility() }
                    Button(model.text("accessibility.openSettings")) { model.openAccessibilitySettings() }
                }
            }

            Section(model.text("settings.accountDirectory")) {
                Text(model.accountDataDirectory.path).font(.caption).textSelection(.enabled)
                Button(model.text("settings.chooseDirectory")) { Task { await model.chooseAccountDataDirectory() } }
                Text(model.text("settings.directoryHint")).font(.caption).foregroundStyle(.secondary)
            }.disabled(!model.ready)
        }.formStyle(.grouped)
        HStack(spacing: 5) {
            Text(model.text("app.footer", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"))
            Link(destination: URL(string: "https://github.com/5hux1n/codexm")!) {
                Image("GitHubMark").renderingMode(.template).resizable().frame(width: 15, height: 15)
            }.accessibilityLabel(model.text("app.repository"))
                .hoverTooltip(model.text("app.repository"))
        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .disabled(model.relocatingAccounts)
        .frame(minWidth: 500, minHeight: 540)
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 3).allowsHitTesting(false) }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.ready, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
            Task { do { try await model.selectRuntime(url) } catch { model.report(error) } }
            return true
        } isTargeted: { dropTargeted = $0 }
        .task {
            while !Task.isCancelled {
                model.refreshAccessibility()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } })
    }
}
