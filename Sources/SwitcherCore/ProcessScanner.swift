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
    /// (ELECTRON_RUN_AS_NODE) for tools. Callable from any thread: Launch Services' list is
    /// thread safe, and it changes only when the main run loop turns.
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

    /// The Claude Code processes of this user that are running a chat: the account's folder
    /// (the path before "/claude-code/") and the chat's CLI session id. Reads every process of
    /// this user, so call it off the main thread.
    public static func liveCLISessions() -> [(pid: pid_t, profileDir: String, cliSessionID: String)] {
        let me = getuid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        var found: [(pid: pid_t, profileDir: String, cliSessionID: String)] = []
        for pid in pids.prefix(Int(got)) where pid > 0 {
            guard owner(pid: pid) == me, let exe = executablePath(pid: pid), exe.contains("/claude-code/"),
                  let args = args(pid: pid),
                  let hit = cliSession(fromArgs: args, executable: exe) else { continue }
            found.append((pid, hit.profileDir, hit.cliSessionID))
        }
        return found
    }

    /// A Claude Code process of an account: executable `<profileDir>/claude-code/<version>/<hash>/claude.app/Contents/MacOS/claude`
    /// run with `--resume=<id>` (or `--resume <id>`). nil for anything else.
    public static func cliSession(fromArgs args: [String], executable: String) -> (profileDir: String, cliSessionID: String)? {
        guard executable.hasSuffix("/claude.app/Contents/MacOS/claude"),
              let marker = executable.range(of: "/claude-code/") else { return nil }
        let profileDir = String(executable[..<marker.lowerBound])
        guard !profileDir.isEmpty else { return nil }
        var id: String?
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "--" { break }
            if a.hasPrefix("--resume=") {
                id = String(a.dropFirst("--resume=".count))
            } else if a == "--resume", i + 1 < args.count {
                id = args[i + 1]
                i += 1
            }
            i += 1
        }
        guard let id, !id.isEmpty, !id.hasPrefix("-") else { return nil }
        return (profileDir, id)
    }

    static func owner(pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_uid : nil
    }

    /// When the process started, in microseconds since 1970; a reused pid has a different one.
    public static func startTime(pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
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
        procArgs(pid: pid).flatMap { parseProcArgs($0) }
    }

    /// The arguments only; the environment (a chat process's may hold credentials) is never decoded.
    public static func args(pid: pid_t) -> [String]? {
        procArgs(pid: pid).flatMap { parseProcArgs($0, environment: false)?.args }
    }

    private static func procArgs(pid: pid_t) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// Layout: argc (Int32), executable path, NUL padding, argc arguments, environment, empty string.
    /// With `environment: false` the parse stops after the arguments and `env` is empty.
    public static func parseProcArgs(_ bytes: [UInt8], environment: Bool = true) -> (args: [String], env: [String])? {
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
        if !environment { return (args, []) }
        var env: [String] = []
        while let s = next(), !s.isEmpty { env.append(s) }
        return (args, env)
    }
}
