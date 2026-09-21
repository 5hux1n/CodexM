import Foundation
import OSLog

enum CodexMError: String, LocalizedError, Sendable {
    case handoffNoDatabase, handoffDatabase, handoffSchema, handoffTranscript, handoffSelection, handoffPackage, handoffProject
    case directoryNotEmpty, defaultAccountProtected, invalidName, codexNotFound, incompatibleRuntime, profileNotFound, profileAlreadyRunning
    case launchFailed, accessibilityDenied, windowNotFound, windowFocusFailed, newWindowUnavailable
    case filesystemError, corruptStorage, unsafePath, profileBusy, processChanged, terminationFailed
    case storageLocked, ambiguousInstance, unavailable, loginItemFailed
    var errorDescription: String? { L10n.text("error.\(rawValue)") }
}

enum Log {
    static let profile = Logger(subsystem: "dev.codexm.app", category: "Profile")
    static let runtime = Logger(subsystem: "dev.codexm.app", category: "Runtime")
    static let process = Logger(subsystem: "dev.codexm.app", category: "Process")
    static let window = Logger(subsystem: "dev.codexm.app", category: "Window")
    static let auth = Logger(subsystem: "dev.codexm.app", category: "Auth")
    static let compatibility = Logger(subsystem: "dev.codexm.app", category: "Compatibility")
    static let ui = Logger(subsystem: "dev.codexm.app", category: "UI")
}

/// All visible strings are looked up in the string catalog. A lock makes error
/// localization safe from services running outside the main actor.
enum L10n {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var selected: AppLanguage = .system
    }
    private static let state = State()
    static func setLanguage(_ language: AppLanguage) { state.lock.lock(); state.selected = language; state.lock.unlock() }
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        state.lock.lock(); let language = state.selected; state.lock.unlock()
        let bundle: Bundle
        if language != .system, let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"), let localized = Bundle(path: path) {
            bundle = localized
        } else { bundle = .main }
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
    }
}
