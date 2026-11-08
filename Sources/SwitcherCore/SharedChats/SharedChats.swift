import Foundation

/// One profile's copy of a chat.
public struct ChatCopy: Equatable {
    public let profileID: String
    public let profileName: String
    public let record: URL
    public let cwd: String
    public let worktreePath: String?
    public let transcript: URL
    public let hasTranscript: Bool
    public let isArchived: Bool
    public let lastActivity: Date
    /// nil = unknown (no worktree, or the lease file could not be read).
    public let leaseHeld: Bool?
    /// The record's cliSessionId when it was scanned; the history file is named after it.
    public let cliSessionID: String
    /// The record's priorCliSessionIds: the histories this one continues (Claude starts a new one on resume).
    public let priorCliSessionIDs: [String]

    public init(profileID: String, profileName: String, record: URL, cwd: String, worktreePath: String?, transcript: URL,
                hasTranscript: Bool, isArchived: Bool, lastActivity: Date, leaseHeld: Bool?,
                cliSessionID: String = "", priorCliSessionIDs: [String] = []) {
        self.profileID = profileID; self.profileName = profileName; self.record = record; self.cwd = cwd
        self.worktreePath = worktreePath; self.transcript = transcript; self.hasTranscript = hasTranscript
        self.isArchived = isArchived; self.lastActivity = lastActivity; self.leaseHeld = leaseHeld
        self.cliSessionID = cliSessionID; self.priorCliSessionIDs = priorCliSessionIDs
    }

    /// This copy's history continues `other`'s: Claude resumed the chat here under a new cliSessionId.
    public func continues(_ other: ChatCopy) -> Bool {
        !other.cliSessionID.isEmpty && other.cliSessionID != cliSessionID && priorCliSessionIDs.contains(other.cliSessionID)
    }
}

public enum CopyRelation {
    /// How two copies' histories relate: line by line when they share a cliSessionId (or nothing says how they
    /// relate), by message ids when one copy's history continues the other's under a new cliSessionId.
    public static func between(_ first: ChatCopy, _ second: ChatCopy,
                               compare: (URL, URL) throws -> TranscriptRelation = TranscriptDiff.compare,
                               continuation: (URL, URL) throws -> TranscriptRelation = TranscriptDiff.compareContinuation) throws -> TranscriptRelation {
        if second.continues(first) { return try continuation(first.transcript, second.transcript) }
        if first.continues(second) { return try continuation(second.transcript, first.transcript).flipped }
        return try compare(first.transcript, second.transcript)
    }
}

public enum CopyStatus: Equatable {
    case latest
    case behind(messages: Int)
    case forked(messages: Int)
    case noTranscript
    case willSplit
    case linkBroken
    case archivedHereOnly
}

/// The own messages of a forked copy and of the reference copy, as counted when the chat was scanned:
/// `reference` = messages only the reference has, `other` = messages only the forked copy has.
public struct ForkCount: Equatable {
    public let reference: Int
    public let other: Int
    public init(reference: Int, other: Int) { self.reference = reference; self.other = other }
}

public struct SharedChat: Equatable, Identifiable {
    /// The record's sessionId.
    public let id: String
    public let cliSessionID: String
    public let title: String
    public let folder: String
    public let copies: [ChatCopy]
    /// profileID -> status
    public let status: [String: CopyStatus]
    public let isLinked: Bool
    /// profileID -> the relation numbers against the reference copy, for every forked copy, taken at scan time.
    public let forkCounts: [String: ForkCount]

    public init(id: String, cliSessionID: String, title: String, folder: String, copies: [ChatCopy],
                status: [String: CopyStatus], isLinked: Bool, forkCounts: [String: ForkCount] = [:]) {
        self.id = id; self.cliSessionID = cliSessionID; self.title = title; self.folder = folder
        self.copies = copies; self.status = status; self.isLinked = isLinked; self.forkCounts = forkCounts
    }

    public var diverged: Bool {
        status.values.contains { $0 != .latest }
    }
}

/// Finds chats whose record exists in two or more profiles and classifies each copy.
public final class SharedChatScanner {
    private let transfer: ChatTransfer
    private let links: () -> [String: Set<String>]
    private let compare: (URL, URL) throws -> TranscriptRelation
    private let continuation: (URL, URL) throws -> TranscriptRelation
    private var cache: [String: TranscriptRelation] = [:]
    private var touched = Set<String>()
    /// Serialises scans: the cache and the touched set belong to one scan at a time.
    private let lock = NSLock()

    public init(transcriptsRoot: URL,
                links: @escaping () -> [String: Set<String>] = { [:] },
                compare: @escaping (URL, URL) throws -> TranscriptRelation = TranscriptDiff.compare,
                continuation: @escaping (URL, URL) throws -> TranscriptRelation = TranscriptDiff.compareContinuation) {
        self.transfer = ChatTransfer(transcriptsRoot: transcriptsRoot)
        self.links = links
        self.compare = compare
        self.continuation = continuation
    }

    private struct Found {
        var copy: ChatCopy
        var cliSessionID: String
        var title: String
    }

    public func scan(_ profiles: [Profile]) -> [SharedChat] {
        lock.lock(); defer { lock.unlock() }
        touched = []
        defer { cache = cache.filter { touched.contains($0.key) } }
        var byID: [String: [Found]] = [:]
        for profile in profiles {
            let leases = WorktreeLeases.read(profile)
            var best: [String: (found: Found, activity: Date)] = [:]
            for account in transfer.subdirectories(ChatTransfer.sessionRoot(profile)) {
                for org in transfer.subdirectories(account) {
                    let deleted = transfer.deletedMarkers(in: org)
                    for file in transfer.records(in: org) {
                        guard let made = makeFound(file: file, raw: transfer.readObject(file), profile: profile, leases: leases, deleted: deleted) else { continue }
                        if let seen = best[made.id], seen.activity >= made.found.copy.lastActivity { continue }
                        best[made.id] = (made.found, made.found.copy.lastActivity)
                    }
                }
            }
            for (id, item) in best { byID[id, default: []].append(item.found) }
        }
        let linked = links()
        return byID.compactMap { id, found in
            found.count >= 2 ? build(id: id, found: found, link: linked[id]) : nil
        }.sorted {
            let a = $0.copies.map(\.lastActivity).max() ?? .distantPast, b = $1.copies.map(\.lastActivity).max() ?? .distantPast
            return a != b ? a > b : $0.id < $1.id
        }
    }

    private func makeFound(file: URL, raw: [String: Any]?, profile: Profile, leases: WorktreeLeases.Read, deleted: Set<String>) -> (id: String, found: Found)? {
        guard let raw else { return nil }
        let base = file.deletingPathExtension().lastPathComponent
        let id = (raw["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? base
        let bare = id.hasPrefix("local_") ? String(id.dropFirst("local_".count)) : id
        if deleted.contains(id) || deleted.contains(bare) { return nil }
        let cli = (raw["cliSessionId"] as? String) ?? ""
        let cwd = (raw["cwd"] as? String) ?? ""
        if cli.isEmpty || cwd.isEmpty || cwd.contains("/scratch-workspaces/") { return nil }
        if let backend = raw["backend"] as? [String: Any], backend["kind"] as? String != "local" { return nil }
        let worktree = (raw["worktreePath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var activity = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let ms = raw["lastActivityAt"] as? NSNumber, ms.doubleValue > 0 { activity = Date(timeIntervalSince1970: ms.doubleValue / 1000) }
        var held: Bool?
        if let worktree, case .ok(let root) = leases { held = WorktreeLeases.holder(of: worktree, in: root) == id }
        let transcript = TranscriptLocator.transcript(root: transfer.transcriptsRoot, cwd: cwd, cliSessionID: cli)
        let copy = ChatCopy(profileID: profile.id, profileName: profile.name, record: file, cwd: cwd, worktreePath: worktree,
                            transcript: transcript, hasTranscript: FileManager.default.fileExists(atPath: transcript.path),
                            isArchived: (raw["isArchived"] as? Bool) ?? false, lastActivity: activity, leaseHeld: held,
                            cliSessionID: cli, priorCliSessionIDs: ((raw["priorCliSessionIds"] as? [Any]) ?? []).compactMap { $0 as? String })
        let title = ((raw["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (id, Found(copy: copy, cliSessionID: cli, title: title.isEmpty ? L("Chat \(bare.prefix(8))", "Sohbet \(bare.prefix(8))") : title))
    }

    /// `link`: the profiles that are part of this chat's link, nil when the chat isn't linked.
    private func build(id: String, found: [Found], link: Set<String>?) -> SharedChat {
        let isLinked = link != nil
        let copies = found.map(\.copy).sorted { $0.profileID < $1.profileID }
        let reference = referenceCopy(copies)
        var status: [String: CopyStatus] = [:]
        var forkCounts: [String: ForkCount] = [:]
        for copy in copies {
            guard copy.hasTranscript, let ref = reference else { status[copy.profileID] = .noTranscript; continue }
            if copy.transcript == ref.transcript { status[copy.profileID] = .latest; continue }
            switch relation(ref, copy) {
            case .some(.identical): status[copy.profileID] = .latest
            case .some(.firstAhead(let n)): status[copy.profileID] = .behind(messages: n)
            case .some(.forked(let first, let own)):
                status[copy.profileID] = .forked(messages: own)
                forkCounts[copy.profileID] = ForkCount(reference: first, other: own)
            // secondAhead cannot remain after the reference search; an unreadable file counts as unusable.
            case .some(.secondAhead), .none: status[copy.profileID] = .noTranscript
            }
        }
        // Precedence, highest first: linkBroken > noTranscript/forked/behind > archivedHereOnly > willSplit > latest.
        let sharing = Dictionary(grouping: copies, by: \.transcript)
        // Only the copies that are part of the link are judged by it; the others keep their ordinary status.
        let inLink = copies.filter { link?.contains($0.profileID) == true }
        let linkRef = reference.flatMap { r in inLink.contains { $0.profileID == r.profileID } ? r : nil } ?? inLink.first
        let someArchived = inLink.contains(where: \.isArchived), someActive = inLink.contains { !$0.isArchived }
        let cwdsDiffer = Set(inLink.map(\.cwd)).count > 1
        for copy in copies {
            let linked = link?.contains(copy.profileID) == true
            if linked && (cwdsDiffer && copy.cwd != linkRef?.cwd || copy.leaseHeld == false) {
                status[copy.profileID] = .linkBroken
            } else if status[copy.profileID] == .latest {
                if linked && someArchived && someActive && copy.isArchived {
                    status[copy.profileID] = .archivedHereOnly
                } else if (sharing[copy.transcript]?.count ?? 0) > 1 && copy.worktreePath != nil && copy.leaseHeld == false {
                    status[copy.profileID] = .willSplit
                }
            }
        }
        let shown = found.max { $0.copy.lastActivity < $1.copy.lastActivity }!
        let folder = URL(fileURLWithPath: (reference ?? copies[0]).cwd).lastPathComponent
        return SharedChat(id: id, cliSessionID: (reference.flatMap { r in found.first { $0.copy.profileID == r.profileID } } ?? shown).cliSessionID,
                          title: shown.title, folder: folder, copies: copies, status: status, isLinked: isLinked, forkCounts: forkCounts)
    }

    /// The copy furthest along: start with the largest history, and let any copy found ahead of the
    /// reference take over (each change is strictly further ahead, so the loop ends).
    private func referenceCopy(_ copies: [ChatCopy]) -> ChatCopy? {
        var candidates = copies.filter(\.hasTranscript)
        candidates.sort {
            let a = size($0.transcript), b = size($1.transcript)
            return a != b ? a > b : $0.lastActivity > $1.lastActivity
        }
        guard var ref = candidates.first else { return nil }
        // A copy is never taken twice, so the loop ends even if two relations disagree.
        var taken: Set<URL> = [ref.transcript]
        var changed = true
        while changed {
            changed = false
            for other in candidates where !taken.contains(other.transcript) {
                if case .some(.secondAhead) = relation(ref, other) {
                    ref = other; taken.insert(other.transcript); changed = true; break
                }
            }
        }
        return ref
    }

    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func fingerprint(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(mtime)"
    }

    private func relation(_ first: ChatCopy, _ second: ChatCopy) -> TranscriptRelation? {
        try? CopyRelation.between(first, second,
                                  compare: { try self.cached("lines", $0, $1, self.compare) },
                                  continuation: { try self.cached("continues", $0, $1, self.continuation) })
    }

    private func cached(_ kind: String, _ first: URL, _ second: URL,
                        _ run: (URL, URL) throws -> TranscriptRelation) throws -> TranscriptRelation {
        let key = kind + "|" + fingerprint(first) + "||" + fingerprint(second)
        touched.insert(key)
        if let hit = cache[key] { return hit }
        let result = try run(first, second)
        cache[key] = result
        return result
    }
}
