import Foundation

/// Who is about to start or write to which profile, shared by the menu bar app and the command line through
/// a file. Claude takes no single-instance lock, so this is what keeps two copies off one data folder in the
/// second before a new process shows up. Every decision runs under one flock; reads are lock-free because
/// the file is replaced atomically.
public final class ProfileClaims {
    public enum LaunchDecision: Equatable { case running(pid_t), starting, writing, go }

    /// How long a launch counts as "starting" before its process is expected to be visible.
    public static let startingWindow: TimeInterval = 20
    /// A writing claim older than this is ignored, in case its owner hung without dying.
    public static let writingLimit: TimeInterval = 600

    private struct Claim: Codable {
        var kind: String
        var pid: Int32
        var since: Date
    }

    private let file: URL
    private let lockFile: URL
    private let now: () -> Date
    private let isAlive: (pid_t) -> Bool
    private let ownPID: pid_t

    public init(file: URL, now: @escaping () -> Date = Date.init, isAlive: @escaping (pid_t) -> Bool = ProfileClaims.processExists,
                ownPID: pid_t = getpid()) {
        self.file = file
        self.lockFile = URL(fileURLWithPath: file.path + ".lock")
        self.now = now
        self.isAlive = isAlive
        self.ownPID = ownPID
    }

    public static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Launching

    /// Decides, atomically across processes, whether this caller may start the profile. `running` is a process
    /// scan and runs under the lock on purpose: a copy that appears between the check and the claim must not slip through.
    public func claimLaunch(_ id: String, running: () -> pid_t?) throws -> LaunchDecision {
        let key = id.lowercased()
        return try FileLock.exclusively(lockFile) {
            if let pid = running() { return .running(pid) }
            var claims = load()
            if let claim = claims[key], isFreshStarting(claim) { return .starting }
            if let claim = claims[key], isLiveWriting(claim) { return .writing }
            claims[key] = Claim(kind: "starting", pid: ownPID, since: now())
            try save(claims)
            return .go
        }
    }

    public func dropStarting(_ id: String) {
        let key = id.lowercased()
        try? FileLock.exclusively(lockFile) {
            var claims = load()
            guard claims[key]?.kind == "starting" else { return }
            claims[key] = nil
            try? save(claims)
        }
    }

    public func startedRecently(_ id: String) -> Bool {
        load()[id.lowercased()].map(isFreshStarting) ?? false
    }

    // MARK: Writing

    /// Claims every profile for a write, or none: throws when one is open, starting or already claimed.
    public func claimWriting(_ profiles: [Profile], isOpen: (Profile) -> Bool) throws {
        try FileLock.exclusively(lockFile) {
            var claims = load()
            for p in profiles {
                let key = p.id.lowercased()
                if isOpen(p) || claims[key].map(isFreshStarting) == true {
                    throw SwitcherError(L("'\(p.name)' is open or starting. Quit it and try again.", "'\(p.name)' açık ya da açılıyor. Kapatıp tekrar deneyin."))
                }
                if claims[key].map(isLiveWriting) == true {
                    throw SwitcherError(L("'\(p.name)' is being updated by the switcher. Try again in a moment.", "'\(p.name)' switcher tarafından güncelleniyor. Birazdan tekrar deneyin."))
                }
            }
            for p in profiles { claims[p.id.lowercased()] = Claim(kind: "writing", pid: ownPID, since: now()) }
            try save(claims)
        }
    }

    public func dropWriting(_ profiles: [Profile]) {
        try? FileLock.exclusively(lockFile) {
            var claims = load()
            for p in profiles where claims[p.id.lowercased()]?.kind == "writing" { claims[p.id.lowercased()] = nil }
            try? save(claims)
        }
    }

    public func isWriting(_ id: String) -> Bool {
        load()[id.lowercased()].map(isLiveWriting) ?? false
    }

    // MARK: File

    private func isFreshStarting(_ claim: Claim) -> Bool {
        claim.kind == "starting" && now().timeIntervalSince(claim.since) < ProfileClaims.startingWindow
    }

    private func isLiveWriting(_ claim: Claim) -> Bool {
        claim.kind == "writing" && now().timeIntervalSince(claim.since) < ProfileClaims.writingLimit && isAlive(claim.pid)
    }

    /// An unreadable file means no claims: a damaged file must never block a launch.
    private func load() -> [String: Claim] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Claim].self, from: data)) ?? [:]
    }

    /// Drops what has expired on every write, so the file does not grow.
    private func save(_ claims: [String: Claim]) throws {
        let live = claims.filter { isFreshStarting($0.value) || isLiveWriting($0.value) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(live).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }
}
