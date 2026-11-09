import Foundation

/*
    Chats two accounts share, kept the same before an account opens. The source is the account used
    last (as for pin sync); for every chat the target shares with it:

    - History: when Claude resumed the chat in the source under a new cliSessionId whose
      priorCliSessionIds name the target's, and the target's history only lags behind it (same
      folder, no messages of its own written after the resume), the target's record takes the
      source's, keeping the fields that belong to the account (bridgeSessionIds, scheduledTaskId,
      MCP settings) and its pin mirror (pin sync owns it). A forked history is left alone and counted.
    - Archive state and title: three-way, against what both accounts last agreed on (kept by the
      switcher, the title only as a hash). A change made on one side only follows; when both sides
      changed, the source wins. Before the first sync there is nothing to compare with: an archived copy
      wins over an unarchived one unless that one was used after it, and a title the user gave wins over one Claude made. Record
      modification times can't decide this: Claude rewrites records while it runs.
    - Deletion: Claude deletes a chat by removing its record and leaving deleted_<id> with the time.
      A chat deleted in the source and not used in the target since then is deleted the same way in
      the target; its record goes to the Trash. One used in the target after the deletion is kept and counted.

    History files live in ~/.claude/projects, shared by every account, and are never touched. Chats only
    one account has are not copied. Nothing is written while the target is open, every record is backed
    up first, and a record that changed since planning is skipped.
*/

struct ChatSyncPlan {
    enum Kind: Equatable {
        case history
        case details(archived: Bool?)
        case deletion(marker: URL, at: String)
    }

    struct Step {
        /// local_<id>
        let id: String
        let file: URL
        /// The record's bytes when it was planned; apply skips a record that no longer has them.
        let seen: Data
        let kind: Kind
        let record: [String: Any]?
    }

    var steps: [Step] = []
    /// Shared chats whose histories went separate ways (messages of their own on both sides).
    var forked = 0
    /// Chats deleted in the source but used in the target after that, so kept.
    var keptAfterDeletion = 0
    /// local_<id> -> what both accounts have once the plan is applied, for every shared chat. A nil field:
    /// the two still differ there (a change made only in the target, for the source to pick up later).
    var agreed: [String: ChatSync.Agreed] = [:]

    var isEmpty: Bool { steps.isEmpty }
}

public struct ChatSyncReport: Equatable {
    public var histories = 0, archived = 0, unarchived = 0, renamed = 0, deleted = 0
    /// Records that changed since planning.
    public var skipped = 0
    /// Writes that failed.
    public var failed = 0
    /// local_<id> of the chats whose step was skipped or failed: what they agreed on is not recorded.
    public var unsettled: Set<String> = []

    public var changed: Int { histories + archived + unarchived + renamed + deleted }
}

enum ChatSync {
    /// Fields that belong to the account a record is in, never taken from another account's record.
    static let accountBound = ["bridgeSessionIds", "scheduledTaskId", "remoteMcpServersConfig", "enabledMcpTools", "isStarred"]
    /// Fields the chat sync makes the same (the archive state, and the title with its bookkeeping).
    static let followed = ["isArchived", "title", "titleSource", "previousTitles"]
    static let titleFields = ["title", "titleSource", "previousTitles"]

    /// What both accounts had for a chat after the last sync: its archive state, and its title as `titleKey`.
    struct Agreed: Equatable, Codable {
        var archived: Bool?
        var title: String?

        /// `newer`'s known fields over these.
        func updated(by newer: Agreed) -> Agreed { Agreed(archived: newer.archived ?? archived, title: newer.title ?? title) }
    }

    /// A stable hash (FNV-1a, 64 bits) of a title, so the agreed state never holds chat titles.
    static func titleKey(_ title: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in title.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    private struct Copy {
        let file: URL
        let raw: [String: Any]
        let data: Data
        let modified: Date
        var cli: String { (raw["cliSessionId"] as? String) ?? "" }
        var cwd: String { (raw["cwd"] as? String) ?? "" }
        var prior: [String] { ((raw["priorCliSessionIds"] as? [Any]) ?? []).compactMap { $0 as? String } }
        /// lastActivityAt in ms, else the file's modification time.
        var activity: Double {
            if let ms = raw["lastActivityAt"] as? NSNumber, ms.doubleValue > 0 { return ms.doubleValue }
            return modified.timeIntervalSince1970 * 1000
        }
    }

    private struct Store {
        /// local_<id> -> its records (a chat can sit in several organisation folders).
        var records: [String: [Copy]] = [:]
        /// bare id -> the deletion time Claude wrote, as written.
        var deleted: [String: String] = [:]
    }

    private static func read(_ profile: Profile, _ transfer: ChatTransfer) -> Store {
        var store = Store()
        for account in transfer.subdirectories(ChatTransfer.sessionRoot(profile)) {
            for org in transfer.subdirectories(account) {
                let markers = transfer.deletedMarkers(in: org)
                for bare in markers {
                    let file = org.appendingPathComponent("deleted_" + bare)
                    let alt = org.appendingPathComponent("deleted_" + bare + ".json")
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: alt, encoding: .utf8)) ?? ""
                    // The latest time wins when several organisation folders deleted it.
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let old = store.deleted[bare], (Double(old) ?? 0) >= (Double(value) ?? 0) { continue }
                    store.deleted[bare] = value
                }
                for file in transfer.records(in: org) {
                    let id = String(file.lastPathComponent.dropLast(".json".count))
                    if markers.contains(String(id.dropFirst("local_".count))) { continue }
                    let real = file.resolvingSymlinksInPath()
                    guard let data = try? Data(contentsOf: real),
                          let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                    let modified = (try? real.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    store.records[id, default: []].append(Copy(file: file, raw: raw, data: data, modified: modified))
                }
            }
        }
        return store
    }

    private static func norm(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `relation(older, newer)` reads two history files the way `TranscriptDiff.compareContinuation` does.
    /// `baseline`: local_<id> -> what both accounts agreed on at the last sync.
    static func plan(target: Profile, source: Profile, transfer: ChatTransfer, baseline: [String: Agreed] = [:],
                     relation: (URL, URL) throws -> TranscriptRelation = TranscriptDiff.compareContinuation) -> ChatSyncPlan {
        let from = read(source, transfer), into = read(target, transfer)
        var plan = ChatSyncPlan()
        for id in into.records.keys.sorted() {
            for copy in into.records[id] ?? [] {
                if let theirs = from.records[id]?.max(by: { $0.modified < $1.modified }) {
                    planShared(id, copy, theirs, base: baseline[id], transfer: transfer, relation: relation, into: &plan)
                } else if let at = from.deleted[String(id.dropFirst("local_".count))] {
                    guard let when = Double(at), when > 0 else { continue }
                    if copy.activity <= when {
                        let marker = copy.file.deletingLastPathComponent().appendingPathComponent("deleted_" + String(id.dropFirst("local_".count)))
                        plan.steps.append(.init(id: id, file: copy.file, seen: copy.data, kind: .deletion(marker: marker, at: at), record: nil))
                    } else {
                        plan.keptAfterDeletion += 1
                    }
                }
            }
        }
        return plan
    }

    private static func planShared(_ id: String, _ mine: Copy, _ theirs: Copy, base: Agreed?, transfer: ChatTransfer,
                                   relation: (URL, URL) throws -> TranscriptRelation, into plan: inout ChatSyncPlan) {
        // Archive state and title: which side's value the target ends with.
        let mineArchived = (mine.raw["isArchived"] as? Bool) ?? false, theirsArchived = (theirs.raw["isArchived"] as? Bool) ?? false
        var takeArchive = false, agreed = Agreed()
        if mineArchived == theirsArchived {
            agreed.archived = mineArchived
        } else if let b = base?.archived {
            takeArchive = mineArchived == b          // only the source changed it (a Bool can't change on both sides)
        } else {
            // Nothing to compare with: archived wins, unless the unarchived copy was used after the archived one.
            let unarchivedLater = theirsArchived ? mine.activity > theirs.activity : theirs.activity > mine.activity
            takeArchive = theirsArchived ? !unarchivedLater : unarchivedLater
        }
        if takeArchive { agreed.archived = theirsArchived }

        let mineTitle = (mine.raw["title"] as? String) ?? "", theirsTitle = (theirs.raw["title"] as? String) ?? ""
        var takeTitle = false
        if mineTitle == theirsTitle {
            agreed.title = titleKey(mineTitle)
        } else if let b = base?.title {
            takeTitle = titleKey(theirsTitle) != b   // kept only when the target alone renamed it
        } else {
            let mineUser = mine.raw["titleSource"] as? String == "user", theirsUser = theirs.raw["titleSource"] as? String == "user"
            takeTitle = !(mineUser && !theirsUser)   // nothing to compare with: a title the user gave wins, else the source's
        }
        if takeTitle { agreed.title = titleKey(theirsTitle) }
        plan.agreed[id] = agreed

        func settle(_ record: inout [String: Any], from copy: Copy, archive: Bool, title: Bool) {
            if archive { record["isArchived"] = copy.raw["isArchived"] }
            if title { for key in titleFields { record[key] = copy.raw[key] } }
        }

        // History: only a continuation in the same folder (one in another folder is the linking's business).
        if !mine.cli.isEmpty, !theirs.cli.isEmpty, mine.cli != theirs.cli, theirs.prior.contains(mine.cli),
           !mine.cwd.isEmpty, norm(mine.cwd) == norm(theirs.cwd) {
            let older = TranscriptLocator.transcript(root: transfer.transcriptsRoot, cwd: mine.cwd, cliSessionID: mine.cli)
            let newer = TranscriptLocator.transcript(root: transfer.transcriptsRoot, cwd: theirs.cwd, cliSessionID: theirs.cli)
            if FileManager.default.fileExists(atPath: newer.path) {
                switch try? relation(older, newer) {
                case .some(.identical), .some(.secondAhead):
                    var record = theirs.raw
                    for key in accountBound { record[key] = mine.raw[key] }
                    // The source's record carries its own archive state and title; keep the target's where it wins.
                    settle(&record, from: mine, archive: !takeArchive && mineArchived != theirsArchived, title: !takeTitle && mineTitle != theirsTitle)
                    plan.steps.append(.init(id: id, file: mine.file, seen: mine.data, kind: .history, record: record))
                    return
                case .some(.forked), .some(.firstAhead):
                    plan.forked += 1
                case .none:
                    break
                }
            }
        }
        guard takeArchive || takeTitle else { return }
        var record = mine.raw
        settle(&record, from: theirs, archive: takeArchive, title: takeTitle)
        plan.steps.append(.init(id: id, file: mine.file, seen: mine.data,
                                kind: .details(archived: takeArchive ? theirsArchived : nil), record: record))
    }

    /// Writes the plan. Throws, writing nothing, when the target is open. `trash` moves a record to the Trash.
    static func apply(_ plan: ChatSyncPlan, to target: Profile, openFolders: [URL],
                      trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> ChatSyncReport {
        if openFolders.contains(where: { ProfileStore.sameItem($0, target.path) }) {
            throw SwitcherError(L("The profile is open; chats were not synced.", "Profil açık; sohbetler eşitlenmedi."), logReason: "profile is open")
        }
        var report = ChatSyncReport()
        for step in plan.steps {
            let real = step.file.resolvingSymlinksInPath()
            guard let now = try? Data(contentsOf: real), now == step.seen else { report.skipped += 1; report.unsettled.insert(step.id); continue }
            do {
                switch step.kind {
                case .deletion(let marker, let at):
                    try trash(step.file)
                    // As Claude leaves it, so the chat stays deleted.
                    if !FileManager.default.fileExists(atPath: marker.path) {
                        try Data(at.utf8).write(to: marker, options: .atomic)
                        chmod(marker.path, 0o600)
                    }
                    report.deleted += 1
                case .history:
                    try write(step.record ?? [:], to: real)
                    report.histories += 1
                case .details(let archived):
                    try write(step.record ?? [:], to: real)
                    switch archived {
                    case true?: report.archived += 1
                    case false?: report.unarchived += 1
                    case nil: report.renamed += 1
                    }
                }
            } catch {
                report.failed += 1
                report.unsettled.insert(step.id)
            }
        }
        return report
    }

    private static func write(_ raw: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try ChatTransfer.backUp(file)
        try data.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }
}

extension ChatSync {
    /// The panel note of a target's chat sync, next to its pin sync note.
    static func noteKey(_ target: Profile) -> String { target.id + " chats" }

    /// The note for what the sync left to the user, nil when nothing was. Counts only, no chat titles.
    static func note(_ plan: ChatSyncPlan, source: Profile, target: Profile) -> String? {
        var parts: [String] = []
        if plan.forked > 0 {
            parts.append(L("\(plan.forked) shared chat(s) went separate ways in '\(source.name)' and '\(target.name)'; keep one with Shared chats.",
                           "\(plan.forked) ortak sohbet '\(source.name)' ve '\(target.name)' hesaplarında ayrı yönlere ilerledi; Ortak sohbetler'den birini seçin."))
        }
        if plan.keptAfterDeletion > 0 {
            parts.append(L("\(plan.keptAfterDeletion) chat(s) deleted in '\(source.name)' were kept in '\(target.name)': they were used there afterwards.",
                           "'\(source.name)' hesabında silinen \(plan.keptAfterDeletion) sohbet '\(target.name)' hesabında tutuldu: sonradan orada kullanıldılar."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Remembers how two history files relate, by their path, size and modification time, so a pair that has not
/// changed is not read again on the next launch (they run to hundreds of MB). Entries not used in a run are dropped on save.
final class RelationCache {
    private let file: URL
    private var stored: [String: String]
    private var used: [String: String] = [:]
    private let lock = NSLock()

    init(file: URL) {
        self.file = file
        let data = try? Data(contentsOf: file)
        stored = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] } ?? [:]
    }

    func wrap(_ run: @escaping (URL, URL) throws -> TranscriptRelation) -> (URL, URL) throws -> TranscriptRelation {
        { older, newer in
            let key = RelationCache.fingerprint(older) + "||" + RelationCache.fingerprint(newer)
            self.lock.lock()
            let hit = self.stored[key].flatMap(RelationCache.decode)
            self.lock.unlock()
            if let hit { self.remember(key, hit); return hit }
            let result = try run(older, newer)
            self.remember(key, result)
            return result
        }
    }

    func save() {
        lock.lock(); let snapshot = used; lock.unlock()
        guard snapshot != stored, let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: file, options: .atomic)) != nil { chmod(file.path, 0o600) }
    }

    private func remember(_ key: String, _ relation: TranscriptRelation) {
        lock.lock(); used[key] = RelationCache.encode(relation); lock.unlock()
    }

    private static func fingerprint(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(mtime)"
    }

    private static func encode(_ r: TranscriptRelation) -> String {
        switch r {
        case .identical: return "identical"
        case .firstAhead(let n): return "first:\(n)"
        case .secondAhead(let n): return "second:\(n)"
        case .forked(let a, let b): return "forked:\(a):\(b)"
        }
    }

    private static func decode(_ s: String) -> TranscriptRelation? {
        let p = s.split(separator: ":").map(String.init)
        switch (p.first, p.count) {
        case ("identical", 1): return .identical
        case ("first", 2): return Int(p[1]).map { .firstAhead(messages: $0) }
        case ("second", 2): return Int(p[1]).map { .secondAhead(messages: $0) }
        case ("forked", 3): if let a = Int(p[1]), let b = Int(p[2]) { return .forked(first: a, second: b) }; return nil
        default: return nil
        }
    }
}

/// What every shared chat's archive state and title were when both accounts last agreed, in the switcher's folder.
/// Holds chat ids and title hashes only. A chat no longer shared is dropped on save.
final class ChatSyncState {
    private let file: URL
    private(set) var agreed: [String: ChatSync.Agreed]

    init(file: URL) {
        self.file = file
        agreed = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: ChatSync.Agreed].self, from: $0) } ?? [:]
    }

    /// Records what a run settled; the chats in `unsettled` keep what they had.
    func record(_ plan: ChatSyncPlan, unsettled: Set<String>) {
        var next: [String: ChatSync.Agreed] = [:]
        for (id, now) in plan.agreed {
            let before = agreed[id] ?? ChatSync.Agreed()
            next[id] = unsettled.contains(id) ? before : before.updated(by: now)
        }
        // Chats deleted in this run are not shared any more; ones only the other direction sees stay.
        for (id, value) in agreed where next[id] == nil && !plan.steps.contains(where: { $0.id == id }) { next[id] = value }
        agreed = next
    }

    func save() {
        guard let data = try? JSONEncoder().encode(agreed) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: file, options: .atomic)) != nil { chmod(file.path, 0o600) }
    }
}
