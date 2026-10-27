import AppKit
import Darwin

/// Finds running Claude desktop instances and the data folder each one uses.
///
/// Claude does not take Electron's single instance lock on macOS (it relies on Launch
/// Services, which knows nothing about --user-data-dir), so two copies on one folder would
/// both start and corrupt it. Knowing exactly which folder is open is therefore what keeps
/// "Launch" from ever starting a second copy of a profile.
public enum ProcessScanner {
    public struct Instance: Equatable {
        public let pid: pid_t
        /// nil: Claude's default folder.
        public let dataDir: String?
    }

    /// Main Claude processes of this user, found by bundle identifier rather than path, so
    /// copies started from a second Claude.app, a translocated download or a different
    /// spelling of the path all count. Launch Services lists only real app processes, which
    /// leaves out helpers (their own bundle ids) and Claude's binary run as Node
    /// (ELECTRON_RUN_AS_NODE) for tools. Must be called on the main thread.
    public static func claudeInstances(bundleID: String) -> [Instance] {
        let me = getuid()
        var found: [Instance] = []
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID && !app.isTerminated {
            let pid = app.processIdentifier
            // Another macOS user's Claude uses that user's folders, never ours.
            guard pid > 0, owner(pid: pid) == me, let (args, env) = argsAndEnv(pid: pid), !isHelper(args: args, env: env) else { continue }
            found.append(Instance(pid: pid, dataDir: dataDir(args: args, env: env)))
        }
        return found
    }

    public static func isHelper(args: [String], env: [String] = []) -> Bool {
        args.contains { $0.hasPrefix("--type=") } || env.contains("ELECTRON_RUN_AS_NODE=1")
    }

    /// The data folder as Chromium reads it: "--user-data-dir=" or "-user-data-dir=", the
    /// last one winning, nothing after "--". nil means the default folder. Claude's own
    /// CLAUDE_USER_DATA_DIR does not count: signed builds delete it at startup and use the
    /// default folder, although the kernel's copy of the environment still shows it.
    public static func dataDir(args: [String], env: [String]) -> String? {
        var dir: String?
        for arg in args.dropFirst() {
            if arg == "--" { break }
            for prefix in ["--user-data-dir=", "-user-data-dir="] where arg.hasPrefix(prefix) {
                dir = String(arg.dropFirst(prefix.count))
            }
        }
        guard var value = dir, !value.isEmpty else { return nil }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return value
    }

    static func owner(pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_uid : nil
    }

    // MARK: Low level

    public static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// argv and environment of a process of this user, read the way ps does (KERN_PROCARGS2).
    /// Exact strings, so a path with spaces ("Application Support") survives intact.
    public static func argsAndEnv(pid: pid_t) -> (args: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Layout: argc (Int32), executable path, NUL padding, argc arguments, environment, empty string.
    public static func parseProcArgs(_ bytes: [UInt8]) -> (args: [String], env: [String])? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        while i < bytes.count, bytes[i] == 0 { i += 1 }

        func next() -> String? {
            guard i < bytes.count else { return nil }
            var j = i
            while j < bytes.count, bytes[j] != 0 { j += 1 }
            let s = String(decoding: bytes[i..<j], as: UTF8.self)
            i = j + 1
            return s
        }

        var args: [String] = []
        while args.count < argc, let s = next() { args.append(s) }
        guard args.count == argc else { return nil }
        var env: [String] = []
        while let s = next(), !s.isEmpty { env.append(s) }
        return (args, env)
    }
}
