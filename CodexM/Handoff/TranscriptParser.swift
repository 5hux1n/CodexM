import Foundation
import Darwin

struct SecretRedactor {
    struct Result { let text: String; let count: Int }
    // Apply to complete extracted fields BEFORE truncation; never export raw JSONL.
    private static let expressions: [NSRegularExpression] = {
        let patterns = [
            "(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)",
            "(?i)\\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[A-Z0-9]{16})\\b",
            "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+",
            "(?i)[\\\"']?(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?(?:token|cookie)|client[_-]?secret|authorization|cookie|secret)[\\\"']?\\s*[:=]\\s*(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)",
            "\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\b",
            "(?i)https?://[^\\s/@]+:[^\\s/@]+@[^\\s]+",
            "(?i)https?://[^\\s]*[?&](?:token|key|signature|sig|password|auth|code)=[^\\s]+"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
    static func clean(_ text: String) -> Result {
        var output = text; var count = 0
        for regex in expressions {
            let range = NSRange(output.startIndex..., in: output)
            count += regex.numberOfMatches(in: output, range: range)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "[REDACTED]")
        }
        return Result(text: output, count: count)
    }
}

struct TranscriptParser {
    static func event(_ data: Data) -> ConversationEvent? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = record["type"] as? String, let payload = record["payload"] as? [String: Any] else { return nil }
        if type == "event_msg", let event = payload["type"] as? String {
            if event == "user_message", let text = payload["message"] as? String { return .init(kind: .user, text: text) }
            if event == "agent_message", let text = payload["message"] as? String { return .init(kind: .assistant, text: text) }
            // Newer paginated histories also persist completed display items.
            // Whitelist public messages and command results; never export reasoning,
            // tool arguments, opaque extension state or binary content.
            if event == "item_completed", let item = payload["item"] as? [String: Any], let kind = item["type"] as? String {
                if ["UserMessage", "AgentMessage"].contains(kind), let parts = item["content"] as? [[String: Any]] {
                    let text = parts.compactMap { part -> String? in
                        guard ["text", "Text"].contains(part["type"] as? String ?? "") else { return nil }
                        return part["text"] as? String
                    }.joined(separator: "\n")
                    if !text.isEmpty { return .init(kind: kind == "UserMessage" ? .user : .assistant, text: text) }
                }
                if kind == "CommandExecution" {
                    let output = item["aggregated_output"] as? String ?? item["formatted_output"] as? String ?? ""
                    let code = (item["exit_code"] as? Int).map(String.init) ?? "unknown"
                    return .init(kind: .tool, text: "Command result (exit \(code))\n\(output)")
                }
                if kind == "McpToolCall", let name = item["tool"] as? String {
                    return .init(kind: .tool, text: "Tool: \(name) (\(item["status"] as? String ?? "unknown"))")
                }
            }
        }
        if type == "response_item", let item = payload["type"] as? String {
            if item == "message", let role = payload["role"] as? String, ["user", "assistant"].contains(role), let content = payload["content"] as? [[String: Any]] {
                let text = content.compactMap { part -> String? in
                    guard ["input_text", "output_text", "text"].contains(part["type"] as? String ?? "") else { return nil }
                    return part["text"] as? String
                }.joined(separator: "\n")
                if !text.isEmpty { return .init(kind: role == "user" ? .user : .assistant, text: text) }
            }
            // Names and redacted text only: no function arguments, internal reasoning or binary blobs.
            if item == "function_call", let name = payload["name"] as? String { return .init(kind: .tool, text: "Tool: " + name) }
            if item == "function_call_output", let text = payload["output"] as? String { return .init(kind: .tool, text: text) }
        }
        return nil
    }
}

actor SessionReader {
    static let maximumBytes: UInt64 = 128 * 1024 * 1024
    func read(thread: ThreadMetadata, home: URL) throws -> TranscriptSnapshot {
        let home = home.standardizedFileURL.resolvingSymlinksInPath()
        let url = try RolloutSource.resolve(thread: thread, home: home)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CodexMError.handoffTranscript }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CodexMError.unsafePath }
        let size = UInt64(max(0, info.st_size))
        var snapshot = TranscriptSnapshot()
        // Huge files: preserve the original request from the head AND recent context from the tail.
        let headLength: UInt64 = 4_194_304
        let tailLength: UInt64 = 16_777_216
        let spans: [(UInt64, UInt64)]
        if size <= Self.maximumBytes { spans = [(0, size)] }
        else { spans = [(0, headLength), (size - tailLength, tailLength)] }
        snapshot.truncated = size > Self.maximumBytes
        for (offset, length) in spans {
            try Task.checkCancellation()
            try file.seek(toOffset: offset)
            var remaining = length; var buffer = Data(); var discardLine = offset != 0
            while remaining > 0 {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: Int(min(remaining, 64 * 1024))), !chunk.isEmpty else { break }
                remaining -= UInt64(chunk.count)
                let lines = chunk.split(separator: 10, omittingEmptySubsequences: false)
                for (index, part) in lines.enumerated() {
                    if !discardLine {
                        if buffer.count + part.count > 1_048_576 {
                            buffer.removeAll(keepingCapacity: true); discardLine = true; snapshot.truncated = true
                        } else { buffer.append(contentsOf: part) }
                    }
                    if index < lines.count - 1 {
                        if !discardLine { append(buffer, into: &snapshot) }
                        else { snapshot.skipped += 1 }
                        buffer.removeAll(keepingCapacity: true); discardLine = false
                    }
                }
            }
            // A writer may still be appending the final record. Never parse a partial line.
            if !buffer.isEmpty || discardLine { snapshot.skipped += 1 }
        }
        guard !snapshot.events.isEmpty else { throw CodexMError.handoffTranscript }
        return snapshot
    }
    private func append(_ data: Data, into result: inout TranscriptSnapshot) {
        guard let event = TranscriptParser.event(data) else { result.skipped += 1; return }
        let clean = SecretRedactor.clean(event.text)
        result.redactions += clean.count
        let limit = event.kind == .tool ? 1200 : 6000
        if event.text.count > limit { result.truncated = true }
        let bounded = String(clean.text.prefix(limit))
        let safe = ConversationEvent(kind: event.kind, text: bounded)
        if result.events.last == safe { return }
        if event.kind == .user, result.originalTask.isEmpty { result.originalTask = bounded }
        if event.kind == .user { result.latestUser = bounded }
        if event.kind == .assistant { result.latestAssistant = bounded }
        result.recognized += 1
        result.events.append(safe)
        if result.events.count > 80 { result.events.removeFirst(); result.truncated = true }
    }
}

/// A relocated account may still have a writer at its original database path.
/// Only accept that file when it is the same history as the account-local copy.
enum RolloutSource {
    static func resolve(thread: ThreadMetadata, home: URL) throws -> URL {
        let home = home.standardizedFileURL
        let raw = (thread.rolloutPath.hasPrefix("/") ? URL(fileURLWithPath: thread.rolloutPath) : home.appendingPathComponent(thread.rolloutPath)).standardizedFileURL
        let roots = ["sessions", "archived_sessions"].map { home.appendingPathComponent($0).path + "/" }
        func validate(_ url: URL) throws {
            try NativeFiles.safe(url)
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { throw CodexMError.unsafePath }
        }
        if roots.contains(where: { raw.path.hasPrefix($0) }) { try validate(raw); return raw }
        let parts = raw.pathComponents
        guard let index = parts.lastIndex(where: { $0 == "sessions" || $0 == "archived_sessions" }) else { throw CodexMError.unsafePath }
        let local = home.appendingPathComponent(parts[index...].joined(separator: "/")).standardizedFileURL
        guard roots.contains(where: { local.path.hasPrefix($0) }) else { throw CodexMError.unsafePath }
        try validate(local)
        guard FileManager.default.fileExists(atPath: raw.path) else { return local }
        try validate(raw)
        // No fallback to an unrelated absolute path when the account copy is missing.
        let localInfo = try local.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let rawInfo = try raw.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard localInfo.isRegularFile == true, rawInfo.isRegularFile == true,
              let localSize = localInfo.fileSize, let rawSize = rawInfo.fileSize, min(localSize, rawSize) > 0 else { throw CodexMError.unsafePath }
        let left = try FileHandle(forReadingFrom: local), right = try FileHandle(forReadingFrom: raw)
        defer { try? left.close(); try? right.close() }
        var remaining = min(localSize, rawSize)
        var last: UInt8?
        while remaining > 0 {
            let count = min(remaining, 65536)
            guard let a = try left.read(upToCount: count), let b = try right.read(upToCount: count), a.count == count, a == b else { throw NativeMigrationError.changed }
            last = a.last; remaining -= count
        }
        guard last == 10 else { throw NativeMigrationError.changed }
        return rawSize > localSize ? raw : local
    }
}
