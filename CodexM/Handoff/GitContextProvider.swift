import Foundation

actor GitContextProvider {
    func read(cwd: String) -> GitContext {
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd) else { return GitContext() }
        guard let root = command(["rev-parse", "--show-toplevel"], cwd: cwd), !root.isEmpty else { return GitContext() }
        guard let files = command(["status", "--short", "--untracked-files=normal"], cwd: cwd),
              let branch = command(["branch", "--show-current"], cwd: cwd),
              let stat = command(["diff", "--stat", "--no-ext-diff", "--no-textconv", "HEAD"], cwd: cwd)
                ?? command(["diff", "--stat", "--no-ext-diff", "--no-textconv"], cwd: cwd) else { return GitContext() }
        return GitContext(available: true, branch: SecretRedactor.clean(branch).text,
            head: command(["rev-parse", "--verify", "HEAD"], cwd: cwd) ?? "", dirty: !files.isEmpty,
            files: SecretRedactor.clean(files).text, diffStat: SecretRedactor.clean(stat).text)
    }
    /// Direct argv; sanitized environment; disable hooks/fsmonitor/external diff. Bound time and output.
    private func command(_ args: [String], cwd: String) -> String? {
        let pipe = Pipe(); let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.quotePath=true"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "C"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var bytes = Data(); var overflow = false
        let deadline = Date().addingTimeInterval(2)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if bytes.count + count <= 24_000 { bytes.append(contentsOf: buffer.prefix(count)) } else { overflow = true }
            } else if count == 0 { break }
            else if errno != EAGAIN && errno != EINTR { break }
            if Date() > deadline || Task.isCancelled { if process.isRunning { process.terminate() }; try? pipe.fileHandleForReading.close(); return nil }
            if count < 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        try? pipe.fileHandleForReading.close()
        // EOF does not guarantee the child has exited. Keep the same deadline.
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        guard !process.isRunning else { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) + (overflow ? "\n[output limited]" : "")
    }
}
