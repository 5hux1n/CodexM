import Foundation

actor AuthMonitor {
    func metadata(profile: Profile, root: URL) -> AuthMetadata? {
        let file = profile.codexHome(in: root).appendingPathComponent("auth.json")
        do {
            let values = try FileManager.default.attributesOfItem(atPath: file.path)
            guard values[.type] as? FileAttributeType == .typeRegular else { return nil }
            return AuthMetadata(exists: true, modified: values[.modificationDate] as? Date, size: (values[.size] as? NSNumber)?.uint64Value ?? 0)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return AuthMetadata(exists: false, modified: nil, size: 0)
        } catch { return nil }
    }
}

struct PendingLogin: Sendable {
    let profileID: UUID
    let createdAt: Date
    var evidenceAt: Date?
}

enum FocusRecoveryPolicy {
    /// A metadata change is only a hint. Automatically correct a wrong Codex
    /// activation briefly, once, and only with a single unambiguous pending login.
    static func target(pending: [PendingLogin], now: Date, frontmostPID: Int32?, instances: [UUID: CodexInstance], codexPIDs: Set<Int32>) -> UUID? {
        let recent = pending.filter { now.timeIntervalSince($0.createdAt) < 300 }
        guard recent.count == 1, let login = recent.first, let evidence = login.evidenceAt,
              now.timeIntervalSince(evidence) >= 0, now.timeIntervalSince(evidence) < 20,
              let target = instances[login.profileID], target.state == .running,
              let frontmostPID, frontmostPID != target.pid, codexPIDs.contains(frontmostPID) else { return nil }
        return login.profileID
    }
}
