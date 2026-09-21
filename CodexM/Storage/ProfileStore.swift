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
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw CodexMError.storageLocked }
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
            } catch { throw CodexMError.corruptStorage }
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
        } catch { throw CodexMError.filesystemError }
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
            try SingletonLockPolicy.validate(target: target, localHostname: ProcessInfo.processInfo.hostName) { pid in
                kill(pid, 0) == 0 || errno == EPERM
            }
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
        } catch { throw CodexMError.filesystemError }
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
    func relocateAccounts(to destination: URL, saving state: StoredState) throws -> StoredState {
        let destination = destination.standardizedFileURL
        guard destination.isFileURL, destination == destination.resolvingSymlinksInPath().standardizedFileURL else { throw CodexMError.unsafePath }
        let accounts = state.profiles.filter { !$0.isInstalledDefault }
        for profile in accounts {
            try assertNotLocked(profile)
            let old = profile.root(in: root).standardizedFileURL.path
            guard !destination.path.hasPrefix(old + "/"), destination.path != old else { throw CodexMError.unsafePath }
        }
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
                    try FileManager.default.copyItem(at: old, to: new)
                }
            }
            updated.preferences.accountDataDirectory = destination.path
            try save(updated)
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
        catch { throw CodexMError.filesystemError }
    }
    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

/// Electron uses gethostname while Foundation may normalize the hostname's case.
/// DNS hostname case is not an ownership boundary; PID liveness still is.
enum SingletonLockPolicy {
    static func validate(target: String, localHostname: String, processAlive: (Int32) -> Bool) throws {
        guard let separator = target.lastIndex(of: "-"),
              let pid = Int32(target[target.index(after: separator)...]), pid > 0 else { throw CodexMError.profileBusy }
        guard !processAlive(pid) else { throw CodexMError.profileBusy }
        let host = String(target[..<separator])
        guard !host.isEmpty, host.caseInsensitiveCompare(localHostname) == .orderedSame else { throw CodexMError.profileBusy }
    }
}
