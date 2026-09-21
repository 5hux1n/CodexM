import Foundation
import Darwin

/// Process identity includes kernel start time, so a recycled PID never grants control.
enum ProcessProbe {
    static func identity(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_status != 5 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, executable: String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    static func matches(_ expected: ProcessIdentity) -> Bool { identity(pid: expected.pid) == expected }

    /// This reader stops after argc strings. It never decodes or returns the environment.
    static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var capacity: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &capacity, &length, nil, 0) == 0, capacity > 0, capacity <= 4_194_304 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(capacity))
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        mib = [CTL_KERN, KERN_PROCARGS2, pid]; length = bytes.count
        guard sysctl(&mib, 3, &bytes, &length, nil, 0) == 0, length > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var cursor = 4
        while cursor < length && bytes[cursor] != 0 { cursor += 1 }
        while cursor < length && bytes[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            guard cursor < length else { return nil }
            let begin = cursor
            while cursor < length && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < length, let argument = String(bytes: bytes[begin..<cursor], encoding: .utf8) else { return nil }
            result.append(argument); cursor += 1
        }
        return result
    }

    static func userDataDirectory(in arguments: [String]) -> String? {
        for (index, arg) in arguments.enumerated() {
            if arg.hasPrefix("--user-data-dir=") { return String(arg.dropFirst("--user-data-dir=".count)) }
            if arg == "--user-data-dir", arguments.indices.contains(index + 1) { return arguments[index + 1] }
        }
        return nil
    }

    static func allIdentities(executables: Set<String>) -> [ProcessIdentity] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard actual > 0 else { return [] }
        return pids.prefix(min(Int(actual), pids.count)).compactMap { pid in
            guard let identity = identity(pid: pid), executables.contains(identity.executable) else { return nil }
            return identity
        }
    }
}
