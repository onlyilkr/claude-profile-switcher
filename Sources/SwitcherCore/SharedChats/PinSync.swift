import Foundation

/*
    Pins of the chats two profiles share. Claude keeps an account's pins in its own store: the
    pinned chats in the account's IndexedDB and their sidebar order in its Local Storage. As
    observed, that store is the source of truth; claude_desktop_config.json and isStarred on
    each chat's record are mirrors that Claude rewrites from it when it starts. Before the
    switcher launches an account, the pins of the shared chats follow the account that was used
    last: its order wins, and the target keeps only its own pins for chats the source does not
    have. The store is written through ClaudePinStore (closed account, backed up, verified); the
    mirrors are updated afterwards and never fail the sync.
*/

struct PinSyncPlan: Equatable {
    /// Profile id the pins come from.
    let source: String
    /// The target's sidebar pin list afterwards.
    let newPins: [String]
    /// local_<id> of chats whose record gets isStarred = true.
    let star: [String]
    /// local_<id> of chats whose record gets isStarred = false.
    let unstar: [String]
    /// The target's pins as the plan saw them; apply refuses when the store no longer holds them.
    let seen: ClaudePins
}

/// What planning found: `skipped` (the source's pins are unreadable or it has no pin record; the
/// target was not read), `noChange` (the target was read and already matches) or a change to apply.
enum PinSyncOutcome {
    case skipped
    case noChange
    case change(PinSyncPlan)

    var change: PinSyncPlan? { if case .change(let plan) = self { return plan }; return nil }
}

public enum PinSync {
    /// The most recently used other profile that shares at least one chat with `target` (when
    /// `transfer` is given) and was used after the target. nil: nothing to sync from.
    /// The source may be open: Claude 4.29 was seen writing a pin change to the list and the
    /// record within seconds, so its files are current.
    public static func source(for target: Profile, among: [Profile], lastUsed: (Profile) -> Date?, transfer: ChatTransfer? = nil,
                              targetIDs: Set<String>? = nil) -> Profile? {
        let targetIDs = targetIDs ?? transfer.map { $0.chatIDs(in: target) }
        let targetDate = lastUsed(target)
        var best: (Profile, Date)?
        for candidate in among where candidate.id != target.id {
            guard let date = lastUsed(candidate) else { continue }
            if let targetDate, date <= targetDate { continue }
            if let best, date <= best.1 { continue }
            if let transfer, let targetIDs, transfer.chatIDs(in: candidate).isDisjoint(with: targetIDs) { continue }
            best = (candidate, date)
        }
        return best?.0
    }

    /// `.skipped` when the source's pins cannot be read or it has no pin record (missing data must
    /// not unpin the target; an unreadable source is logged through `logError` with a fixed reason),
    /// `.noChange` when nothing would change. Throws when the target has no pin record yet.
    /// `targetIDs` saves walking the target's folders again when the caller already has them.
    static func plan(target: Profile, source: Profile, transfer: ChatTransfer, targetIDs: Set<String>? = nil,
                     logError: (String) -> Void) throws -> PinSyncOutcome {
        // The source may be running, so its files can end in a half-written entry.
        let sourcePins: ClaudePins
        do {
            guard let pins = try ClaudePinStore.read(source, tolerateTornTail: true) else { return .skipped }
            sourcePins = pins
        } catch {
            logError("Pin sync for '\(target.name)' skipped: source pins unreadable")
            return .skipped
        }
        guard let targetPins = try ClaudePinStore.read(target, tolerateTornTail: false) else { throw noPinRecord(target) }
        let sourceIDs = transfer.chatIDs(in: source)
        let targetIDs = targetIDs ?? transfer.chatIDs(in: target)
        let shared = sourceIDs.intersection(targetIDs)

        var seen = Set<String>()
        var list: [String] = []
        for pin in sourcePins.sidebar where shared.contains(pin) && seen.insert(pin).inserted { list.append(pin) }
        for pin in targetPins.sidebar where !sourceIDs.contains(pin) && seen.insert(pin).inserted { list.append(pin) }

        // Records of shared chats are checked against the new list, so a run that stopped
        // halfway (store written, some records not) is repaired the next time pins sync into this account.
        let after = Set(list)
        let states = transfer.recordStars(of: shared, in: target)
        let star = list.filter { shared.contains($0) && states[$0]?.contains(false) == true }
        let unstar = shared.filter { !after.contains($0) && states[$0]?.contains(true) == true }.sorted()

        if list == targetPins.sidebar && targetPins.starred == list && star.isEmpty && unstar.isEmpty { return .noChange }
        return .change(PinSyncPlan(source: source.id, newPins: list, star: star, unstar: unstar, seen: targetPins))
    }

    /// Writes Claude's pin store, then the mirrors. Nothing is written when the target is open or
    /// its pins are no longer what the plan saw. Mirror failures go to `logError` (fixed reasons) and
    /// do not fail the sync: Claude rewrites the mirrors from its store at startup.
    static func apply(_ plan: PinSyncPlan, to target: Profile, transfer: ChatTransfer, openFolders: [URL], backups: URL,
                      logError: (String) -> Void) throws {
        if openFolders.contains(where: { ProfileStore.sameItem($0, target.path) }) {
            throw SwitcherError(L("The profile is open; pins were not synced.", "Profil açık; pinler eşitlenmedi."), logReason: "profile is open")
        }
        guard try ClaudePinStore.read(target, tolerateTornTail: false) == plan.seen else {
            throw SwitcherError(L("The pins changed since they were read; pins were not synced.", "Pinler okunduktan sonra değişti; eşitlenmedi."),
                                logReason: "pins changed since planning")
        }
        _ = try ClaudePinStore.write(plan.newPins, to: target, backups: backups)

        // Mirrors, also when the store was already right: a records-only repair still has to happen.
        let name = target.name
        if transfer.pins(of: target) != plan.newPins {
            do { try transfer.writePins(plan.newPins, to: target, openFolders: openFolders) }
            catch { logError("Pin sync for '\(name)': config mirror not updated") }
        }
        let failed = transfer.setStarred(true, ids: plan.star, in: target) + transfer.setStarred(false, ids: plan.unstar, in: target)
        if failed > 0 { logError("Pin sync for '\(name)': \(failed) record mirror(s) not updated") }
    }

    private static func noPinRecord(_ profile: Profile) -> SwitcherError {
        SwitcherError(L("Claude has not saved pins in '\(profile.name)' yet. Pin one chat there once, then pin sync can follow.",
                        "Claude '\(profile.name)' hesabında henüz pin kaydetmedi. Orada bir sohbeti bir kez pinleyin, sonra pin eşitleme çalışır."),
                      logReason: "no pin record yet")
    }
}

extension ChatTransfer {
    /// local_<id> of every chat with a record in the profile, from file names only. A chat
    /// with a deleted marker in the same organisation folder is left out.
    func chatIDs(in profile: Profile) -> Set<String> {
        var ids = Set<String>()
        for account in subdirectories(ChatTransfer.sessionRoot(profile)) {
            for org in subdirectories(account) {
                let deleted = deletedMarkers(in: org)
                for file in records(in: org) {
                    let id = String(file.lastPathComponent.dropLast(".json".count))
                    if deleted.contains(String(id.dropFirst("local_".count))) { continue }
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    /// isStarred of every record of these chats (absent counts as false), per chat; only these
    /// records are parsed.
    func recordStars(of ids: Set<String>, in profile: Profile) -> [String: [Bool]] {
        var out: [String: [Bool]] = [:]
        for account in subdirectories(ChatTransfer.sessionRoot(profile)) {
            for org in subdirectories(account) {
                let deleted = deletedMarkers(in: org)
                for file in records(in: org) {
                    let id = String(file.lastPathComponent.dropLast(".json".count))
                    guard ids.contains(id), !deleted.contains(String(id.dropFirst("local_".count))),
                          let raw = readObject(file) else { continue }
                    out[id, default: []].append((raw["isStarred"] as? Bool) ?? false)
                }
            }
        }
        return out
    }

    /// Sets isStarred in every record of these chats (a chat can sit in several organisation
    /// folders); a record that already has the value is not rewritten. Returns how many
    /// records could not be written.
    func setStarred(_ value: Bool, ids: [String], in profile: Profile) -> Int {
        guard !ids.isEmpty else { return 0 }
        var failed = 0
        let wanted = Set(ids.map { $0 + ".json" })
        for account in subdirectories(ChatTransfer.sessionRoot(profile)) {
            for org in subdirectories(account) {
                let deleted = deletedMarkers(in: org)
                for file in records(in: org) where wanted.contains(file.lastPathComponent) {
                    if deleted.contains(String(file.lastPathComponent.dropFirst("local_".count).dropLast(".json".count))) { continue }
                    let real = file.resolvingSymlinksInPath()
                    guard var raw = readObject(real) else { failed += 1; continue }
                    // Absent counts as false: pinning adds the key, unpinning an absent key changes nothing.
                    if ((raw["isStarred"] as? Bool) ?? false) == value { continue }
                    raw["isStarred"] = value
                    do { try write(raw, to: real) } catch { failed += 1 }
                }
            }
        }
        return failed
    }

    private func write(_ raw: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try ChatTransfer.backUp(file)
        try data.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }
}
