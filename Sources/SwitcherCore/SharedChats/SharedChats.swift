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

    public init(profileID: String, profileName: String, record: URL, cwd: String, worktreePath: String?, transcript: URL,
                hasTranscript: Bool, isArchived: Bool, lastActivity: Date, leaseHeld: Bool?) {
        self.profileID = profileID; self.profileName = profileName; self.record = record; self.cwd = cwd
        self.worktreePath = worktreePath; self.transcript = transcript; self.hasTranscript = hasTranscript
        self.isArchived = isArchived; self.lastActivity = lastActivity; self.leaseHeld = leaseHeld
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

    public init(id: String, cliSessionID: String, title: String, folder: String, copies: [ChatCopy],
                status: [String: CopyStatus], isLinked: Bool) {
        self.id = id; self.cliSessionID = cliSessionID; self.title = title; self.folder = folder
        self.copies = copies; self.status = status; self.isLinked = isLinked
    }

    public var diverged: Bool {
        status.values.contains { $0 != .latest }
    }
}

/// Finds chats whose record exists in two or more profiles and classifies each copy.
public final class SharedChatScanner {
    private let transfer: ChatTransfer
    private let linkedSessionIDs: () -> Set<String>
    private let compare: (URL, URL) throws -> TranscriptRelation
    private var cache: [String: TranscriptRelation] = [:]
    private var touched = Set<String>()
    /// Serialises scans: the cache and the touched set belong to one scan at a time.
    private let lock = NSLock()

    public init(transcriptsRoot: URL,
                linkedSessionIDs: @escaping () -> Set<String> = { [] },
                compare: @escaping (URL, URL) throws -> TranscriptRelation = TranscriptDiff.compare) {
        self.transfer = ChatTransfer(transcriptsRoot: transcriptsRoot)
        self.linkedSessionIDs = linkedSessionIDs
        self.compare = compare
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
        let linked = linkedSessionIDs()
        return byID.compactMap { id, found in
            found.count >= 2 ? build(id: id, found: found, isLinked: linked.contains(id)) : nil
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
                            isArchived: (raw["isArchived"] as? Bool) ?? false, lastActivity: activity, leaseHeld: held)
        let title = ((raw["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (id, Found(copy: copy, cliSessionID: cli, title: title.isEmpty ? "Chat \(bare.prefix(8))" : title))
    }

    private func build(id: String, found: [Found], isLinked: Bool) -> SharedChat {
        let copies = found.map(\.copy).sorted { $0.profileID < $1.profileID }
        let reference = referenceCopy(copies)
        var status: [String: CopyStatus] = [:]
        for copy in copies {
            guard copy.hasTranscript, let ref = reference else { status[copy.profileID] = .noTranscript; continue }
            if copy.transcript == ref.transcript { status[copy.profileID] = .latest; continue }
            switch relation(ref.transcript, copy.transcript) {
            case .some(.identical): status[copy.profileID] = .latest
            case .some(.firstAhead(let n)): status[copy.profileID] = .behind(messages: n)
            case .some(.forked(_, let own)): status[copy.profileID] = .forked(messages: own)
            // secondAhead cannot remain after the reference search; an unreadable file counts as unusable.
            case .some(.secondAhead), .none: status[copy.profileID] = .noTranscript
            }
        }
        // Precedence, highest first: linkBroken > noTranscript/forked/behind > archivedHereOnly > willSplit > latest.
        let sharing = Dictionary(grouping: copies, by: \.transcript)
        let someArchived = copies.contains(where: \.isArchived), someActive = copies.contains { !$0.isArchived }
        let cwdsDiffer = Set(copies.map(\.cwd)).count > 1
        for copy in copies {
            if isLinked && (cwdsDiffer && copy.cwd != reference?.cwd || copy.leaseHeld == false) {
                status[copy.profileID] = .linkBroken
            } else if status[copy.profileID] == .latest {
                if isLinked && someArchived && someActive && copy.isArchived {
                    status[copy.profileID] = .archivedHereOnly
                } else if (sharing[copy.transcript]?.count ?? 0) > 1 && copy.worktreePath != nil && copy.leaseHeld == false {
                    status[copy.profileID] = .willSplit
                }
            }
        }
        let shown = found.max { $0.copy.lastActivity < $1.copy.lastActivity }!
        let folder = URL(fileURLWithPath: (reference ?? copies[0]).cwd).lastPathComponent
        return SharedChat(id: id, cliSessionID: (reference.flatMap { r in found.first { $0.copy.profileID == r.profileID } } ?? shown).cliSessionID,
                          title: shown.title, folder: folder, copies: copies, status: status, isLinked: isLinked)
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
        var changed = true
        while changed {
            changed = false
            for other in candidates where other.transcript != ref.transcript {
                if case .some(.secondAhead) = relation(ref.transcript, other.transcript) {
                    ref = other; changed = true; break
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

    private func relation(_ first: URL, _ second: URL) -> TranscriptRelation? {
        let key = fingerprint(first) + "||" + fingerprint(second)
        touched.insert(key)
        if let hit = cache[key] { return hit }
        guard let result = try? compare(first, second) else { return nil }
        cache[key] = result
        return result
    }
}
