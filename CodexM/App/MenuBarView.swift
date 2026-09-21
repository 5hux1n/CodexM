import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @State private var hoveredProfileID: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CodexM").font(.headline)
                Spacer()
                Text(model.text("menu.running", model.runningCount)).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            if !model.ready {
                Text(model.text(model.loadFailed ? "storage.failed" : "app.loading")).font(.callout).padding()
            } else if model.profiles.isEmpty {
                Text(model.text("profile.emptyDescription")).font(.callout).foregroundStyle(.secondary).padding()
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.profiles) { profile in
                            HStack(spacing: 4) {
                                Button {
                                    model.menuPanelCloser?(); Task { await model.activate(profile); if model.errorMessage != nil { model.openDashboard() } }
                                } label: {
                                    HStack {
                                        Image(systemName: model.state(profile).symbol).font(.caption).frame(width: 16)
                                            .foregroundStyle(model.state(profile) == .running ? Color.green : Color.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(profile.name).lineLimit(1)
                                            Text(model.text("state.\(model.state(profile).rawValue)")).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()

                                    }.padding(.vertical, 7).padding(.horizontal, 8).contentShape(Rectangle())
                                }.buttonStyle(.borderless)
                                    .disabled(model.busyProfiles.contains(profile.id) || model.blockedProfiles.contains(profile.id) || model.isQuitting)
                                if model.state(profile) == .running, let windows = model.windows[profile.id], !windows.isEmpty {
                                    Button { model.windowPickerProfile = profile; model.openDashboard() } label: {
                                        HStack(spacing: 3) {
                                            Image("ActionWindows").renderingMode(.template).resizable().frame(width: 13, height: 13)
                                            Text("\(windows.count)").font(.caption).monospacedDigit()
                                        }.foregroundStyle(.secondary)
                                    }.buttonStyle(.plain).focusEffectDisabled().hoverTooltip(model.text("window.count", windows.count))
                                }
                                if model.state(profile) == .running {
                                    Button(model.text("action.stop")) { Task { await model.stop(profile) } }
                                        .buttonStyle(.bordered).controlSize(.small).font(.caption).fixedSize()
                                            .disabled(model.busyProfiles.contains(profile.id))
                                } else if !model.state(profile).isActive {
                                    Button(model.text("action.launch")) {
                                        model.menuPanelCloser?(); Task { await model.launch(profile) }
                                    }.buttonStyle(.bordered).controlSize(.small).font(.caption).fixedSize()
                                        .disabled(model.busyProfiles.contains(profile.id) || model.blockedProfiles.contains(profile.id))
                                }
                                ProfileMenuButton(profile: profile, model: model)
                                    .id(profile.id)
                                    .frame(width: 18, height: 24).padding(.trailing, 6)
                                    .disabled(model.busyProfiles.contains(profile.id) || model.isQuitting)
                            }
                            .frame(height: 44)
                            .background(
                                Color(nsColor: .selectedContentBackgroundColor)
                                    .opacity(hoveredProfileID == profile.id ? 0.14 : 0),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .onHover { inside in
                                if inside { hoveredProfileID = profile.id }
                                else if hoveredProfileID == profile.id { hoveredProfileID = nil }
                            }
                        }
                    }.padding(6)
                }.frame(height: min(350, CGFloat(model.profiles.count) * 47 + 9))
            }
            Divider()
            VStack(spacing: 2) {
                HStack {
                    navigation("NavHandoff", "handoff.title") { model.openHandoff() }.disabled(!model.ready)
                    Spacer()
                    navigation("NavAdd", "profile.add") { model.showAddProfile = true; model.openDashboard() }.disabled(!model.ready)
                    Spacer()
                    navigation("NavAccounts", "menu.open") { model.openDashboard() }
                    Spacer()
                    navigation("NavSettings", "settings.title") { model.openSettings() }
                    Spacer()
                    navigation("NavQuit", "app.quit") { model.menuPanelCloser?(); NSApp.terminate(nil) }
                }.padding(.horizontal, 8)
            }.padding(6)
        }.frame(width: 292)
    }
    private func navigation(_ asset: String, _ key: String, action: @escaping () -> Void) -> some View {
        CompactIconButton(asset: asset, title: model.text(key), action: action)
    }
}
