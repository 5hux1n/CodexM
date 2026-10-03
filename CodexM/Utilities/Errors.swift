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

/// Only stable identifiers and numeric OS codes enter reports. Never include
/// NSError descriptions/userInfo, SQL, paths, account names or history excerpts.
struct AppFailure: Error, LocalizedError, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let code: String
    let operation: String
    let messageKey: String
    let technical: String?
    var impactKey: String? = nil
    var appVersion: String? = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { $0 + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")" }
    var osVersion: String? = ProcessInfo.processInfo.operatingSystemVersionString
    var runtimeVersion: String? = nil

    static func identifier(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) }.prefix(100))
    }
    static func capture(_ error: Error, operation: String) -> AppFailure {
        if let failure = error as? AppFailure { return failure }
        var code: String, key: String, technical: String?
        var stage = operation
        var reference = UUID(), occurredAt = Date()
        if let detail = error as? NativeMigrationDiagnostic {
            stage = "native." + detail.stage
            reference = detail.reference ?? reference; occurredAt = detail.timestamp ?? occurredAt
            code = "CM-NATIVE-" + identifier(detail.stage) + "-" + identifier(detail.code)
            key = "diagnostic.nativeFailure"
            if detail.code.hasPrefix("sqlite-"), let status = Int(detail.code.split(separator: "-").last ?? "") {
                key = databaseMessage(status)
            } else if detail.stage == "occupancy", detail.code.hasPrefix("openFile-") || detail.code.hasPrefix("clientLock-") { key = "native.error.busy"
            } else if NativeMigrationError(rawValue: detail.code) != nil { key = "native.error." + detail.code }
            technical = [identifier(detail.code), detail.extendedCode.map { "sqliteExtended=\($0)" }, detail.systemCode.map { "errno=\($0)" }, detail.database.map { (detail.stage == "occupancy" ? "resource=" : "database=") + identifier($0) }].compactMap { $0 }.joined(separator: "; ")
        } else if let known = error as? CodexMError {
            code = "CM-APP-" + known.rawValue; key = "error." + known.rawValue
        } else if let known = error as? NativeMigrationError {
            code = "CM-NATIVE-" + known.rawValue; key = "native.error." + known.rawValue
        } else if error is DecodingError {
            code = "CM-DATA-decode"; key = operation.hasPrefix("handoff.") ? "error.handoffPackage" : (operation.hasPrefix("native.") ? "diagnostic.migrationRecord" : "error.corruptStorage")
        } else {
            let ns = error as NSError
            let domain: String
            switch ns.domain {
            case NSCocoaErrorDomain: domain = "Cocoa"
            case NSPOSIXErrorDomain: domain = "POSIX"
            case NSOSStatusErrorDomain: domain = "OSStatus"
            case NSURLErrorDomain: domain = "URL"
            default: domain = "Other"
            }
            code = "CM-SYSTEM-\(domain)-\(ns.code)"; key = "diagnostic.unexpected"
            technical = "\(domain)=\(ns.code)"
            if ns.domain == NSCocoaErrorDomain {
                if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) { key = "diagnostic.fileAccess" }
                else if [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) { key = "diagnostic.fileMissing" }
                else if ns.code == NSFileWriteOutOfSpaceError { key = "diagnostic.diskFull" }
                else if error is DecodingError { key = "error.corruptStorage" }
            } else if ns.domain == NSPOSIXErrorDomain {
                if [1, 13].contains(ns.code) { key = "diagnostic.fileAccess" }
                else if ns.code == 2 { key = "diagnostic.fileMissing" }
                else if ns.code == 28 { key = "diagnostic.diskFull" }
            }
        }
        return AppFailure(id: reference, timestamp: occurredAt, code: code, operation: identifier(stage), messageKey: key, technical: technical)
    }
    static func databaseMessage(_ status: Int) -> String {
        switch status & 255 {
        case 14, 3, 8: return "diagnostic.databaseAccess"
        case 5, 6: return "diagnostic.databaseBusy"
        case 11, 26: return "diagnostic.databaseDamaged"
        case 13: return "diagnostic.diskFull"
        default: return "diagnostic.databaseFailure"
        }
    }
    var errorDescription: String? {
        let stageKey = operation.hasPrefix("native.") ? "native.stage." + String(operation.dropFirst(7)) : "diagnostic.operation." + operation
        let localized = L10n.text(stageKey)
        let stage = localized == stageKey ? operation : localized
        return L10n.text(messageKey) + "\n\n" + L10n.text("diagnostic.details", code, stage, String(id.uuidString.prefix(8))) + (technical.map { "\n" + $0 } ?? "") + (impactKey.map { "\n\n" + L10n.text($0) } ?? "")
    }
}

/// Bounded local journal survives relaunch and can be copied from Settings.
/// Logging failure must never interrupt or replace the original operation.
enum DiagnosticJournal {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var entries: [AppFailure] = []
        var url: URL?
    }
    private static let state = State()
    static func configure(root: URL) {
        state.lock.lock(); defer { state.lock.unlock() }
        let url = root.appendingPathComponent("diagnostics.json")
        state.url = url
        state.entries = []
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256000,
              let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([AppFailure].self, from: data) else { return }
        // Validate stored fields before sharing; this is diagnostic data, not instructions.
        state.entries = Array(entries.filter {
            $0.code == AppFailure.identifier($0.code) && $0.operation == AppFailure.identifier($0.operation) &&
            ($0.messageKey.hasPrefix("error.") || $0.messageKey.hasPrefix("native.error.") || $0.messageKey.hasPrefix("diagnostic.")) &&
            $0.messageKey == AppFailure.identifier($0.messageKey) && ($0.technical?.count ?? 0) <= 200
        }.suffix(100))
    }
    static func record(_ failure: AppFailure, coalesce: Bool = false) {
        state.lock.lock(); defer { state.lock.unlock() }
        if coalesce, let previous = state.entries.last(where: { $0.code == failure.code && $0.operation == failure.operation }), failure.timestamp.timeIntervalSince(previous.timestamp) < 60 { return }
        Log.diagnostic.error("\(failure.code, privacy: .public) operation=\(failure.operation, privacy: .public) ref=\(failure.id.uuidString, privacy: .public)")
        state.entries.removeAll { $0.id == failure.id }
        state.entries.append(failure); state.entries = Array(state.entries.suffix(100))
        guard let url = state.url, url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { return }
        do {
            let data = try JSONEncoder().encode(state.entries)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { Log.diagnostic.error("Diagnostic journal could not be saved") }
    }
    static func snapshot() -> [AppFailure] {
        state.lock.lock(); defer { state.lock.unlock() }; return state.entries
    }
}

enum Log {
    static let diagnostic = Logger(subsystem: "dev.codexm.app", category: "Diagnostic")
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
