import SwiftUI
import AppKit

struct HandoffView: View {
    @Bindable var model: AppModel
    var close: () -> Void = {}
    @State private var sourceID: UUID?
    @State private var targetID: UUID?
    @State private var threadID: String?
    @State private var threads: [ThreadMetadata] = []
    @State private var search = ""
    @State private var draft: HandoffDraft?
    @State private var context = ""
    @State private var package: HandoffPackage?
    @State private var history: [HandoffPackage] = []
    @State private var loading = false
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var copied = false
    @State private var confirmRecovery = false
    @State private var nativeMode = true
    @State private var sourcePaused = false
    @State private var nativeRecord: NativeMigrationRecord?
    @State private var nativeHistory: [NativeMigrationRecord] = []
    private var source: Profile? { model.profiles.first { $0.id == sourceID } }
    private var target: Profile? { model.profiles.first { $0.id == targetID } }
    private var thread: ThreadMetadata? { threads.first { $0.id == threadID } }
    private var visibleThreads: [ThreadMetadata] { threads.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.cwd.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(model.text("handoff.title"), systemImage: "arrow.left.arrow.right").font(.title2.bold())
                Spacer()
                if loading || working { ProgressView().controlSize(.small) }
            }.overlay { HandoffDragArea() }
            if let nativeRecord { nativeResult(nativeRecord) }
            else if let package { result(package) }
            else if let draft { preview(draft) }
            else { selection.disabled(working) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                if draft != nil || package != nil || nativeRecord != nil {
                    Button(model.text("handoff.back")) { draft = nil; package = nil; nativeRecord = nil; error = nil; copied = false; refreshHistory() }.disabled(working)
                }
                Spacer()
                Button(model.text("action.close")) { task?.cancel(); close() }.keyboardShortcut(.cancelAction).disabled(working)
                if nativeMode, nativeRecord == nil, package == nil {
                    Button(model.text("native.import")) { importNative() }.buttonStyle(.borderedProminent)
                        .disabled(loading || working || !sourcePaused || source == nil || target == nil || thread == nil || sourceID == targetID || model.relocatingAccounts || target.map { model.state($0).isActive } == true)
                } else if let draft, package == nil {
                    Button(model.text("handoff.execute")) { commit(draft) }.buttonStyle(.borderedProminent).disabled(working || context.isEmpty)
                } else if package == nil && nativeRecord == nil {
                    Button(model.text("handoff.preview")) { prepare() }.buttonStyle(.borderedProminent)
                        .disabled(loading || working || source == nil || target == nil || sourceID == targetID || thread == nil || model.relocatingAccounts)
                }
            }
        }.padding(24).frame(minWidth: 680, minHeight: 620)
        .confirmationDialog(model.text("native.recoverConfirm"), isPresented: $confirmRecovery, titleVisibility: .visible) {
            Button(model.text("native.recover")) { if let nativeRecord { rollbackNative(nativeRecord, recoverInterrupted: true) } }
            Button(model.text("action.cancel"), role: .cancel) {}
        }
        .interactiveDismissDisabled(working)
        .onAppear {
            sourceID = model.handoffSourceID ?? model.profiles.first?.id
            targetID = model.profiles.first(where: { $0.id != sourceID })?.id
            refreshHistory()
        }
        .onChange(of: sourceID) { _, _ in
            sourcePaused = false; nativeRecord = nil
            if sourceID == targetID { targetID = model.profiles.first(where: { $0.id != sourceID })?.id }
            loadThreads()
        }
        .onChange(of: threadID) { _, _ in sourcePaused = false }
        .onChange(of: targetID) { _, _ in sourcePaused = false }
        .onChange(of: model.handoffSourceID) { _, id in
            if let id, !working, id != sourceID {
                draft = nil; package = nil; nativeRecord = nil; context = ""; error = nil
                sourceID = id
            }
        }
        .onChange(of: working) { _, value in model.handoffWorking = value }
        .onDisappear { task?.cancel(); model.handoffWorking = false }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(model.text("native.mode"), selection: $nativeMode) {
                Text(model.text("native.mode.native")).tag(true)
                Text(model.text("native.mode.context")).tag(false)
            }.pickerStyle(.segmented)
            if nativeMode {
                Text(model.text("native.intro")).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Picker(model.text("handoff.from"), selection: $sourceID) {
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(model.text("handoff.to"), selection: $targetID) {
                    Text(model.text("handoff.chooseTarget")).tag(nil as UUID?)
                    ForEach(model.profiles.filter { $0.id != sourceID }) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            TextField(model.text("handoff.search"), text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Text(model.text("handoff.tasks")).font(.headline)
                Spacer()
                Button(model.text("runtime.detect")) { loadThreads() }.disabled(loading)
            }
            List(visibleThreads, selection: $threadID) { thread in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(thread.title.isEmpty ? model.text("window.untitled") : thread.title).lineLimit(1)
                        if thread.archived { Text(model.text("handoff.archived")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(thread.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(thread.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.padding(.vertical, 3).tag(thread.id)
            }.overlay { if visibleThreads.isEmpty && !loading { Text(model.text("handoff.empty")).foregroundStyle(.secondary) } }
                .frame(minHeight: 170)
            if nativeMode {
                Toggle(model.text("native.paused"), isOn: $sourcePaused)
                if let target, model.state(target).isActive {
                    HStack {
                        Text(model.text("native.targetRunning")).font(.caption)
                        Button(model.text("native.stopTarget")) { Task { await model.stop(target) } }
                    }
                }
                if !nativeHistory.isEmpty {
                    DisclosureGroup(model.text("native.recent")) {
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(nativeHistory) { record in
                                    Button { nativeRecord = record; error = nil } label: {
                                        HStack {
                                            Text(record.title).lineLimit(1)
                                            Spacer()
                                            Text(model.text("native.status.\(record.status)")).font(.caption)
                                        }
                                    }.buttonStyle(.link)
                                }
                            }
                        }.frame(maxHeight: 80)
                    }
                }
            }
            Text(model.text("handoff.localHint")).font(.caption).foregroundStyle(.secondary)
            if !nativeMode, !history.isEmpty {
                DisclosureGroup(model.text("handoff.recent")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(history) { entry in
                                Button {
                                    package = entry; context = entry.context; draft = nil; error = nil
                                } label: {
                                    HStack {
                                        Text(entry.manifest.source.threadTitle).lineLimit(1)
                                        Spacer()
                                        Text(model.text("handoff.status.\(entry.manifest.status.rawValue)")).font(.caption)
                                        Text(entry.manifest.createdAt, style: .date).font(.caption)
                                    }
                                }.buttonStyle(.link)
                            }
                        }.padding(.top, 6)
                    }.frame(maxHeight: 100)
                }
            }
        }
    }
    private func preview(_ draft: HandoffDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(source?.name ?? "") → \(target?.name ?? "")").font(.headline)
            Text(draft.manifest.source.threadTitle).font(.subheadline)
            Text(draft.manifest.project.cwd).font(.caption).textSelection(.enabled)
            HStack {
                Text(model.text("handoff.events", draft.manifest.eventCount, draft.redactions))
                Spacer()
                Text(draft.manifest.git.available ? "\(draft.manifest.git.branch) · \(draft.manifest.git.head.prefix(8))" : model.text("handoff.noGit"))
            }.font(.caption).foregroundStyle(.secondary)
            Text(model.text(draft.manifest.limited ? "handoff.limited" : "handoff.reviewHint")).font(.caption).foregroundStyle(.secondary)
            GroupBox {
                TextEditor(text: $context)
                    .font(.system(.caption, design: .monospaced))
                    .textEditorStyle(.plain)
                    .accessibilityLabel(model.text("handoff.context"))
                    .onChange(of: context) { _, value in if value.count > ContextBuilder.budget { context = String(value.prefix(ContextBuilder.budget)) } }
            }
            Text(model.text("handoff.pauseHint")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func result(_ package: HandoffPackage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.text("handoff.ready"), systemImage: "checkmark.circle").font(.headline)
            Text(package.manifest.source.threadTitle)
            Text(model.text("handoff.targetName", model.profiles.first(where: { $0.id == package.manifest.target.profileId })?.name ?? model.text("handoff.missingAccount")))
            Text(package.manifest.project.cwd).font(.caption).textSelection(.enabled)
            Text(model.text("handoff.manual")).font(.callout).foregroundStyle(.secondary)
            GroupBox {
                ScrollView {
                    Text(package.context).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button(model.text(copied ? "handoff.copied" : "handoff.copy")) { copy(package) }
                Button(model.text("handoff.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([package.contextURL]) }
                Spacer()
                Button(model.text("handoff.openTarget")) { openTarget(package) }.disabled(working)
            }
        }
    }
    private func message(_ error: Error) -> String { (error as? NativeMigrationDiagnostic)?.errorDescription ?? (error as? NativeMigrationError)?.errorDescription ?? (error as? CodexMError)?.errorDescription ?? model.text("error.handoffPackage") }
    private func loadThreads() {
        task?.cancel(); let id = UUID(); requestID = id
        threads = []; threadID = nil; error = nil; loading = true
        guard let source else { loading = false; return }
        task = Task {
            do {
                let result = try await model.handoffCoordinator.readThreads(profile: source, root: model.dataRoot)
                guard !Task.isCancelled, requestID == id else { return }
                threads = result; threadID = result.first?.id; loading = false
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                self.error = message(error); loading = false
            }
        }
    }
    private func prepare() {
        guard let source, let target, let thread else { return }
        working = true; error = nil
        task = Task {
            defer { working = false }
            do {
                let result = try await model.handoffCoordinator.prepare(thread: thread, source: source, target: target, root: model.dataRoot)
                try Task.checkCancellation()
                draft = result; context = result.context
            } catch { if !Task.isCancelled { self.error = message(error) } }
        }
    }
    private func commit(_ original: HandoffDraft) {
        working = true; error = nil
        task = Task {
            defer { working = false }
            do {
                var draft = original; draft.context = context
                let saved = try await model.handoffStore.save(draft)
                package = saved; copy(saved)
                await launchTarget(saved)
            } catch { self.error = message(error) }
        }
    }
    private func copy(_ package: HandoffPackage) {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(package.continuation, forType: .string)
    }
    private func openTarget(_ package: HandoffPackage) {
        working = true; error = nil; copy(package)
        task = Task { await launchTarget(package); working = false }
    }
    private func launchTarget(_ original: HandoffPackage) async {
        guard let target = model.profiles.first(where: { $0.id == original.manifest.target.profileId }) else { error = model.text("error.profileNotFound"); return }
        guard !model.previewMode else { error = model.text("handoff.previewMode"); return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: original.manifest.project.cwd, isDirectory: &directory), directory.boolValue else { error = model.text("error.handoffProject"); return }
        await model.launchHandoffTarget(target)
        let status: HandoffStatus = model.state(target) == .running ? .launched : .failed
        do { package = try await model.handoffStore.update(original, status: status) }
        catch { self.error = message(error) }
        if status == .failed { error = model.text("handoff.launchFailed") }
    }
    private func nativeResult(_ record: NativeMigrationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(model.text("native.status.\(record.status)"), systemImage: record.status == "verified" ? "checkmark.circle" : "info.circle").font(.headline)
            Text(record.title).font(.headline)
            Text(record.project).font(.caption).textSelection(.enabled)
            Text(model.text("native.threadID", record.threadID)).font(.caption).textSelection(.enabled)
            if let detail = record.diagnostic { Text(detail.errorDescription ?? "").foregroundStyle(.red).font(.callout) }
            else if let code = record.failureCode { Text(model.text(code)).foregroundStyle(.red).font(.callout) }
            if let evidence = record.evidence {
                Text(model.text("native.evidence", evidence.turns, evidence.items))
            }
            Text(model.text(record.status == "verified" ? "native.next" : "native.recoveryHint"))
                .font(.callout).foregroundStyle(.secondary)
            Text(model.text("native.rollbackHint")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button(model.text("native.backup")) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.dataRoot.appendingPathComponent("NativeMigrations").appendingPathComponent(record.id.uuidString)])
                }
                Button(model.text("native.rollback")) { rollbackNative(record) }
                    .disabled(working || !["verified", "failed"].contains(record.status))
                if ["importing", "restoring"].contains(record.status) {
                    Button(model.text("native.recover")) { confirmRecovery = true }.disabled(working)
                }
                Spacer()
                if record.status == "verified" {
                    Button(model.text("native.openTarget")) {
                        working = true; error = nil
                        task = Task { await launchNativeTarget(record); working = false }
                    }.buttonStyle(.borderedProminent).disabled(working)
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }
    private func importNative() {
        guard let source, let target, let thread, sourcePaused else { return }
        working = true; error = nil
        task = Task {
            defer { working = false; refreshHistory() }
            do {
                let record = try await model.importNative(thread: thread, source: source, target: target)
                nativeRecord = record
                if record.status == "verified" { await launchNativeTarget(record) }
            }
            catch { self.error = message(error) }
        }
    }
    private func launchNativeTarget(_ record: NativeMigrationRecord) async {
        guard record.status == "verified" else { return }
        guard let target = model.profiles.first(where: { $0.id == record.targetProfile }) else {
            error = model.text("error.profileNotFound"); return
        }
        await model.launchHandoffTarget(target)
        if model.state(target) != .running { error = model.text("native.launchFailed") }
    }
    private func rollbackNative(_ record: NativeMigrationRecord, recoverInterrupted: Bool = false) {
        working = true; error = nil
        task = Task {
            defer { working = false; refreshHistory() }
            do { nativeRecord = try await model.rollbackNative(record, recoverInterrupted: recoverInterrupted) }
            catch { self.error = message(error) }
        }
    }
    private func refreshHistory() {
        Task {
            do { history = try await model.handoffStore.recent(); nativeHistory = try await model.nativeMigration.recent(root: model.dataRoot) }
            catch { self.error = message(error) }
        }
    }
}

/// A native drag surface also makes the in-content heading draggable.
/// SwiftUI's hosting view otherwise consumes clicks in the window background.
private struct HandoffDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
