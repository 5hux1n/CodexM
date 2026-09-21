import SwiftUI

struct DashboardView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.text("dashboard.title")).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(model.text("dashboard.summary", model.profiles.count, model.runningCount))
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }.padding(.horizontal, 2)
                    if model.loadFailed {
                        NoticeView(icon: "exclamationmark.triangle", message: model.text("storage.failed"))
                    } else if model.storageError {
                        NoticeView(icon: "externaldrive.badge.exclamationmark", message: model.text("storage.writeFailed"), actionTitle: model.text("action.retry")) { Task { await model.persist() } }
                    }
                    if model.runtime == nil {
                        NoticeView(icon: "app.dashed", message: model.text("runtime.missing"), actionTitle: model.text("runtime.locate")) { Task { await model.locateRuntime() } }
                    }
                    if model.compatibilityChanged {
                        NoticeView(icon: "arrow.triangle.2.circlepath", message: model.text("runtime.updated"), actionTitle: model.text("action.dismiss")) { model.acknowledgeCompatibility() }
                    }
                    if model.profiles.isEmpty, model.ready {
                        ContentUnavailableView {
                            Label(model.text("profile.empty"), systemImage: "square.stack.3d.up")
                        } description: { Text(model.text("profile.emptyDescription")) } actions: {
                            Button(model.text("profile.add")) { model.showAddProfile = true }.buttonStyle(.borderedProminent).controlSize(.small)
                        }.frame(minHeight: 170)
                    } else {
                        let columns = max(1, min(3, Int((geometry.size.width - 14) / 220)))
                        let width = min(236.0, (geometry.size.width - 24 - Double(columns - 1) * 10) / Double(columns))
                        ForEach(0..<((model.profiles.count + columns - 1) / columns), id: \.self) { row in
                            HStack(spacing: 10) {
                                ForEach(Array(model.profiles.dropFirst(row * columns).prefix(columns))) { profile in
                                    ProfileCard(profile: profile, model: model).frame(width: width).transition(.opacity)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(12).frame(maxWidth: 752).frame(maxWidth: .infinity)
            }

        }
        }
        .frame(minWidth: 460, minHeight: 220)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.profiles.map(\.id))
        .modifier(Presentations(model: model))
    }
}
