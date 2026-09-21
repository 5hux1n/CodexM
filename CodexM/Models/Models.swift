import Foundation

struct Profile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var launchOnStartup = false
    var restoreOnLaunch = true
    var lastLaunchedAt: Date?
    // Optional for compatibility with metadata written before default-account support.
    var origin: String?
    var storageDirectory: String?
    var isInstalledDefault: Bool { origin == "installedDefault" }
    static let installedDefaultID = UUID(uuidString: "86B766AA-85AB-49BD-89A0-D85791DEB001")!
    static func installedDefault(name: String) -> Profile {
        Profile(id: installedDefaultID, name: name, createdAt: Date(), restoreOnLaunch: false, origin: "installedDefault")
    }

    func root(in dataRoot: URL) -> URL { if isInstalledDefault { return FileManager.default.homeDirectoryForCurrentUser }; return (storageDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? dataRoot.appendingPathComponent("Profiles", isDirectory: true)).appendingPathComponent(id.uuidString, isDirectory: true) }
    func codexHome(in dataRoot: URL) -> URL { if isInstalledDefault { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }; return root(in: dataRoot).appendingPathComponent("codex", isDirectory: true) }
    func electronHome(in dataRoot: URL) -> URL { if isInstalledDefault { return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex") }; return root(in: dataRoot).appendingPathComponent("electron", isDirectory: true) }

    static func validatedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, !name.unicodeScalars.contains(where: { [Unicode.GeneralCategory.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }) else {
            throw CodexMError.invalidName
        }
        return name
    }
}

enum InstanceState: String, Codable, Sendable {
    case stopped, launching, running, terminating, crashed, error
    var isActive: Bool { [.launching, .running, .terminating].contains(self) }
    var symbol: String {
        switch self {
        case .stopped: return "circle"
        case .launching: return "circle.lefthalf.filled"
        case .running: return "circle.fill"
        case .terminating: return "stop.circle"
        case .crashed, .error: return "exclamationmark.circle"
        }
    }
}

struct ProcessIdentity: Codable, Hashable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String
}

struct CodexInstance: Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    let identity: ProcessIdentity
    let launchedAt: Date
    var state: InstanceState
    var recovered: Bool
    var pid: Int32 { identity.pid }
}

struct RuntimeRecord: Codable, Sendable {
    let profileID: UUID
    let identity: ProcessIdentity
    let launchedAt: Date
}

struct CodexWindow: Identifiable, Hashable, Sendable {
    let id: UUID
    let pid: Int32
    let title: String
    let number: UInt32?
    let isMinimized: Bool
    let isFocused: Bool
}

struct RuntimeInfo: Equatable, Sendable {
    let appURL: URL
    let executableURL: URL
    let bundleID: String
    let version: String
    let build: String
    var fingerprint: String { "\(version) (\(build))" }
}

enum AppLanguage: String, Codable, CaseIterable, Sendable { case system, en, zhHans = "zh-Hans" }
enum ClickBehavior: String, Codable, CaseIterable, Sendable { case lastWindow, showWindows }
struct Preferences: Codable, Sendable {
    var language: AppLanguage = .system
    var restoreRunningProfiles = false
    var quitManagedInstances = false
    var clickBehavior: ClickBehavior = .lastWindow
    var selectedRuntimePath: String?
    var accountDataDirectory: String?
    var acknowledgedRuntimeVersion: String?
    var onboardingComplete = false
    var previouslyRunning: Set<UUID> = []
}

struct StoredState: Codable, Sendable {
    var schemaVersion = 1
    var profiles: [Profile] = []
    var preferences = Preferences()
    var runtimeRecords: [RuntimeRecord] = []
}

enum AuthState: String, Sendable { case unknown, signedOut, signingIn, signedIn }
struct AuthMetadata: Equatable, Sendable {
    let exists: Bool
    let modified: Date?
    let size: UInt64
}
