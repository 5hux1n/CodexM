import SwiftUI

struct ProfileCard: View {
    let profile: Profile
    @Bindable var model: AppModel
    private var running: Bool { model.state(profile) == .running }
    private var unavailable: Bool { model.busyProfiles.contains(profile.id) || model.isQuitting }

    var body: some View {
        GroupBox {
            cardContent
                .padding(2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(profile.name)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(profile.name.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(profile.name)
                        Spacer(minLength: 2)
                        if profile.isInstalledDefault {
                            Text(model.text("account.local")).font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .fixedSize()
                        }
                    }
                    HStack {
                        StateBadge(state: model.state(profile), model: model).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 2)
                        if running, let count = model.windows[profile.id]?.count, count > 0 {
                            HStack(spacing: 3) {
                                Image("ActionWindows").renderingMode(.template).resizable().frame(width: 13, height: 13)
                                Text("\(count)").monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .hoverTooltip(model.text("window.openCount", count))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(model.text("window.openCount", count))
                        } else if model.state(profile) == .launching || model.state(profile) == .terminating {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
            }
            if model.blockedProfiles.contains(profile.id) {
                Text(model.text("profile.inUse")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.pendingLogins[profile.id] != nil {
                HStack(spacing: 5) {
                    Text(model.text("auth.\((model.authStates[profile.id] ?? .unknown).rawValue)"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    icon("ActionReturn", "auth.return") { Task { await model.focus(profile) } }
                }
            }
            actionButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if running {
                icon("ActionFocus", "action.focus") { Task { await model.activate(profile) } }
                icon("ActionNewWindow", "action.newWindow") { Task { await model.newWindow(profile) } }
                icon("ActionRestart", "action.restart") { Task { await model.stop(profile, restart: true) } }
                icon("ActionStop", model.timedOutProfiles.contains(profile.id) ? "action.forceQuit" : "action.stop") {
                    if model.timedOutProfiles.contains(profile.id) { model.forceQuitProfile = profile }
                    else { Task { await model.stop(profile) } }
                }
            } else {
                icon("ActionLaunch", "action.launch") { Task { await model.launch(profile) } }
                    .disabled(model.blockedProfiles.contains(profile.id) || model.runtime == nil || model.state(profile).isActive)
            }
            icon("ActionEdit", "action.edit") { model.editingProfile = profile }
            if !profile.isInstalledDefault {
                CompactIconButton(asset: "ActionDelete", title: model.text("action.delete"), destructive: true, outlineOnly: true) { model.deletingProfile = profile }
                    .disabled(model.state(profile).isActive || model.blockedProfiles.contains(profile.id))
            }
        }
        .disabled(unavailable)
    }

    private func icon(_ asset: String, _ key: String, action: @escaping () -> Void) -> some View {
        CompactIconButton(asset: asset, title: model.text(key), outlineOnly: true, action: action)
    }
}

struct CompactIconButton: View {
    let asset: String
    let title: String
    var destructive = false
    var outlineOnly = false
    let action: () -> Void
    var body: some View {
        NativeCompactButton(asset: asset, title: title, destructive: destructive, outlineOnly: outlineOnly, action: action)
            .frame(width: 28, height: 26)
            .overlay {
                if outlineOnly {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct NativeCompactButton: NSViewRepresentable {
    let asset: String
    let title: String
    let destructive: Bool
    let outlineOnly: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isBordered = !outlineOnly
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let image = NSImage(named: asset)?.copy() as? NSImage
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        button.image = image
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.isBordered = !outlineOnly
        button.isEnabled = context.environment.isEnabled
        button.contentTintColor = destructive ? .systemRed : nil
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func performAction() { action() }
    }
}
