import Foundation

enum NativeMigrationError: String, Error, LocalizedError {
    case runtime, capability, busy, conflict, incompatible, unsupported, changed, invalid, helper, rollbackChanged, recovery
    var errorDescription: String? { L10n.text("native.error.\(rawValue)") }
}

/// Contains only our stage identifier and a numeric RPC / local error code.
/// Official error messages can contain history excerpts, so they are not persisted.
struct NativeMigrationDiagnostic: Error, LocalizedError, Codable, Sendable {
    let stage: String
    let code: String
    var errorDescription: String? { L10n.text("native.error.diagnostic", L10n.text("native.stage.\(stage)"), code) }
}

struct NativeEvidence: Codable, Sendable, Equatable {
    let turns: Int
    let items: Int
    let historyHash: String
}
struct NativeMigrationRecord: Codable, Identifiable, Sendable {
    var formatVersion = 1
    let id: UUID
    let createdAt: Date
    let sourceProfile: UUID
    let targetProfile: UUID
    let threadID: String
    let title: String
    let project: String
    let targetHome: String
    let rolloutRelative: String
    let rolloutHash: String
    let runtimeVersion: String
    var status: String = "prepared"
    var before: [String: String] = [:]
    var after: [String: String] = [:]
    var evidence: NativeEvidence?
    var diagnostic: NativeMigrationDiagnostic?
    var loadedRolloutHash: String?
    var failureCode: String?
    var containsCredentials = false
}
