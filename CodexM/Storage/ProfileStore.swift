import Foundation
import Darwin

/// Serializes all metadata transactions and holds a cross-process application lease.
/// Profile data and authentication files are never decoded by this store.
actor ProfileStore {
    nonisolated let root: URL
    private var lockFD: Int32 = -1
    private var current = StoredState()
    private var loaded = false
    private let moveToTrash: @Sendable (URL) throws -> URL?

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexM", isDirectory: true), moveToTrash: @escaping @Sendable (URL) throws -> URL? = ProfileStore.systemTrash) {
        self.root = root; self.moveToTrash = moveToTrash
    }
    nonisolated static func systemTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }

    func load() throws -> StoredState {
        if loaded { return current }
        try ensureDirectory(root)
        let lease = root.appendingPathComponent("manager.lock")
        guard !isSymlink(lease) else { throw CodexMError.unsafePath }
        lockFD = open(lease.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw AppFailure.capture(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), operation: "storage.lock") }
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            let status = errno
            if status == EWOULDBLOCK { throw CodexMError.storageLocked }
            throw AppFailure.capture(NSError(domain: NSPOSIXErrorDomain, code: Int(status)), operation: "storage.lock")
        }
        let file = root.appendingPathComponent("profiles.json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard !isSymlink(file) else { throw CodexMError.unsafePath }
            do {
                current = try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: file))
                guard current.schemaVersion == 1, Set(current.profiles.map(\.id)).count == current.profiles.count else { throw CodexMError.corruptStorage }
                for profile in current.profiles {
                    _ = try Profile.validatedName(profile.name)
                    guard profile.origin == nil || (profile.isInstalledDefault && profile.id == Profile.installedDefaultID) else { throw CodexMError.corruptStorage }
                }
            } catch { throw AppFailure.capture(error, operation: "storage.load") }
        }
        try ensureDirectory(root.appendingPathComponent("Profiles", isDirectory: true))
        loaded = true
        return current
    }

    func save(_ state: StoredState) throws {
        guard loaded else { throw CodexMError.corruptStorage }
        let url = root.appendingPathComponent("profiles.json")
        guard !isSymlink(url) else { throw CodexMError.unsafePath }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            current = state
        } catch { throw AppFailure.capture(error, operation: "storage.save") }
    }

    func prepare(_ profile: Profile) throws {
        if profile.isInstalledDefault { return } // The official app owns creation and permissions.
        guard loaded else { throw CodexMError.corruptStorage }
        try ensureDirectory(root)
        try ensureDirectory(root.appendingPathComponent("Profiles", isDirectory: true))
        try ensureDirectory(profile.root(in: root).deletingLastPathComponent())
        try ensureDirectory(profile.root(in: root))
        try ensureDirectory(profile.codexHome(in: root))
        try ensureDirectory(profile.electronHome(in: root))
    }

    func assertNotLocked(_ profile: Profile) throws {
        try validateTree(profile)
        let lock = profile.electronHome(in: root).appendingPathComponent("SingletonLock")
        // Electron owns this lock. Never remove it or attempt to repair it.
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path) {
            try SingletonLockPolicy.validate(target: target, directory: lock.deletingLastPathComponent())
        } else if FileManager.default.fileExists(atPath: lock.path) { throw CodexMError.profileBusy }
    }

    func delete(_ profile: Profile, saving state: StoredState) throws {
        guard !profile.isInstalledDefault else { throw CodexMError.defaultAccountProtected }
        try validateTree(profile)
        try assertNotLocked(profile)
        let original = profile.root(in: root)
        var trashed: URL?
        do {
            if FileManager.default.fileExists(atPath: original.path) {
                trashed = try moveToTrash(original)
            }
            do { try save(state) }
            catch {
                if let trashed { try? FileManager.default.moveItem(at: trashed, to: original) }
                throw error
            }
        } catch { throw AppFailure.capture(error, operation: "account.delete") }
    }

    func validateTree(_ profile: Profile) throws {
        if profile.isInstalledDefault {
            for url in [profile.codexHome(in: root), profile.electronHome(in: root)] {
                guard !isSymlink(url) else { throw CodexMError.unsafePath }
            }
            return
        }
        for url in [root, profile.root(in: root).deletingLastPathComponent(), profile.root(in: root), profile.codexHome(in: root), profile.electronHome(in: root)] {
            guard !isSymlink(url), url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw CodexMError.unsafePath }
        }
    }

    /// Copy first, commit metadata atomically, then retain old folders as a rollback backup.
    /// No credential contents are parsed and official default data is never moved.
    func relocateAccounts(to destination: URL, saving state: StoredState, progress: @escaping @Sendable (Double?) -> Void = { _ in }) throws -> StoredState {
        progress(nil)
        let destination = destination.standardizedFileURL
        guard destination.isFileURL, destination == destination.resolvingSymlinksInPath().standardizedFileURL else { throw CodexMError.unsafePath }
        let accounts = state.profiles.filter { !$0.isInstalledDefault }
        for profile in accounts {
            try assertNotLocked(profile)
            let old = profile.root(in: root).standardizedFileURL.path
            guard !destination.path.hasPrefix(old + "/"), destination.path != old else { throw CodexMError.unsafePath }
        }
        let sources = accounts.filter { $0.root(in: root).deletingLastPathComponent().standardizedFileURL != destination && FileManager.default.fileExists(atPath: $0.root(in: root).path) }.map { $0.root(in: root) }
        let reporter = RelocationCopyProgress(total: try RelocationCopyProgress.size(of: sources), report: progress)
        reporter.emit(force: true)
        try ensureDirectory(destination)
        var updated = state
        var copied: [URL] = []
        do {
            for index in updated.profiles.indices where !updated.profiles[index].isInstalledDefault {
                let old = updated.profiles[index].root(in: root)
                updated.profiles[index].storageDirectory = destination.path
                let new = updated.profiles[index].root(in: root)
                if old.standardizedFileURL == new.standardizedFileURL { continue }
                guard !FileManager.default.fileExists(atPath: new.path), !isSymlink(new) else { throw CodexMError.directoryNotEmpty }
                if FileManager.default.fileExists(atPath: old.path) {
                    copied.append(new)
                    try reporter.copy(from: old, to: new)
                    // Singleton IPC belongs to the old location. Leave the original
                    // untouched and let Electron create fresh links at the destination.
                    let electron = updated.profiles[index].electronHome(in: root)
                    for name in ["SingletonLock", "SingletonCookie", "SingletonSocket"] {
                        let transient = electron.appendingPathComponent(name)
                        if isSymlink(transient) || FileManager.default.fileExists(atPath: transient.path) {
                            try FileManager.default.removeItem(at: transient)
                        }
                    }
                }
            }
            updated.preferences.accountDataDirectory = destination.path
            try save(updated)
            progress(1)
            return updated
        } catch {
            for url in copied { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        guard !isSymlink(url) else { throw CodexMError.unsafePath }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CodexMError.unsafePath }
        } catch let error as CodexMError { throw error }
        catch { throw AppFailure.capture(error, operation: "storage.directory") }
    }
    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

/// A hostname change can leave Electron locks with the previous machine name.
/// On a verified local volume, a dead PID makes that lock stale. Remote or
/// unknown volumes still require a matching hostname; never delete the lock.
enum SingletonLockPolicy {
    static func validate(target: String, directory: URL) throws {
        let local = (try? directory.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
        try validate(target: target, localHostname: ProcessInfo.processInfo.hostName, localVolume: local) { pid in
            if kill(pid, 0) == 0 { return true }
            // Only ESRCH proves absence. Permissions and other failures are unknown.
            return errno != ESRCH
        }
    }

    static func validate(target: String, localHostname: String, localVolume: Bool = false, processAlive: (Int32) -> Bool) throws {
        guard let separator = target.lastIndex(of: "-"),
              let pid = Int32(target[target.index(after: separator)...]), pid > 0 else { throw CodexMError.profileBusy }
        guard !processAlive(pid) else { throw CodexMError.profileBusy }
        let host = String(target[..<separator])
        guard !host.isEmpty, localVolume || host.caseInsensitiveCompare(localHostname) == .orderedSame else { throw CodexMError.profileBusy }
    }
}

/// Used synchronously on ProfileStore's executor. The C callback does not escape copyfile.
private final class RelocationCopyProgress {
    let total: Int64
    let report: @Sendable (Double?) -> Void
    var completed: Int64 = 0
    var current: Int64 = 0
    var lastUpdate = Date.distantPast
    init(total: Int64, report: @escaping @Sendable (Double?) -> Void) { self.total = total; self.report = report }

    static func size(of roots: [URL]) throws -> Int64 {
        var total: Int64 = 0
        for root in roots {
            var failure: Error?
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], errorHandler: { _, error in failure = error; return false }) else { throw CodexMError.filesystemError }
            for case let file as URL in walker {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
            }
            if let failure { throw failure }
        }
        return total
    }
    func emit(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastUpdate) >= 0.1 else { return }
        lastUpdate = Date()
        report(total > 0 ? min(0.99, Double(completed + current) / Double(total)) : 0)
    }
    func copy(from source: URL, to destination: URL) throws {
        guard let state = copyfile_state_alloc() else { throw CodexMError.filesystemError }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: copyfile_callback_t = { what, stage, state, _, _, context in
            guard let context, stage != COPYFILE_ERR, what != COPYFILE_RECURSE_ERROR else { return COPYFILE_QUIT }
            let reporter = Unmanaged<RelocationCopyProgress>.fromOpaque(context).takeUnretainedValue()
            if what == COPYFILE_COPY_DATA {
                var bytes: off_t = 0
                if stage == COPYFILE_START { reporter.current = 0 }
                if stage == COPYFILE_PROGRESS || stage == COPYFILE_FINISH {
                    if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes) == 0 { reporter.current = max(0, Int64(bytes)) }
                    if stage == COPYFILE_FINISH { reporter.completed += reporter.current; reporter.current = 0 }
                    reporter.emit()
                }
            }
            return COPYFILE_CONTINUE
        }
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context) == 0 else { throw CodexMError.filesystemError }
        guard copyfile(source.path, destination.path, state, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        emit(force: true)
    }
}
