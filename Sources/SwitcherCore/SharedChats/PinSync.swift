import Foundation

/*
    Pins of the chats two profiles share. Claude keeps a profile's pins twice: the ordered
    list in claude_desktop_config.json and isStarred on each chat's record, and the two sets
    match. Before the switcher launches an account, the pins of the shared chats follow the
    account that was used last: its order wins, the target keeps only its own pins for chats
    the source does not have.
*/

public struct PinSyncPlan: Equatable {
    /// Profile id the pins come from.
    public let source: String
    /// The target's pin list afterwards.
    public let newPins: [String]
    /// local_<id> of chats whose record gets isStarred = true.
    public let star: [String]
    /// local_<id> of chats whose record gets isStarred = false.
    public let unstar: [String]
    /// The target's pin list as the plan saw it; apply refuses when the file no longer holds it.
    public let seenPins: [String]
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

    /// nil when nothing would change, or when the source's config exists but cannot be read
    /// (an unreadable source must not unpin the target). `targetIDs` saves walking the target's
    /// folders again when the caller already has them.
    public static func plan(target: Profile, source: Profile, transfer: ChatTransfer, targetIDs: Set<String>? = nil) -> PinSyncPlan? {
        let sourceConfig = ChatTransfer.configFile(source)
        if FileManager.default.fileExists(atPath: sourceConfig.path), transfer.readObject(sourceConfig) == nil { return nil }
        let sourceIDs = transfer.chatIDs(in: source)
        let targetIDs = targetIDs ?? transfer.chatIDs(in: target)
        let shared = sourceIDs.intersection(targetIDs)
        let sourcePins = transfer.pins(of: source)
        let targetPins = transfer.pins(of: target)

        var seen = Set<String>()
        var list: [String] = []
        for pin in sourcePins where shared.contains(pin) && seen.insert(pin).inserted { list.append(pin) }
        for pin in targetPins where !sourceIDs.contains(pin) && seen.insert(pin).inserted { list.append(pin) }

        // Records of shared chats are checked against the new list, so a run that stopped
        // halfway (list written, some records not) is repaired the next time pins sync into this account.
        let after = Set(list)
        let states = transfer.recordStars(of: shared, in: target)
        let star = list.filter { shared.contains($0) && states[$0]?.contains(false) == true }
        let unstar = shared.filter { !after.contains($0) && states[$0]?.contains(true) == true }.sorted()

        if list == targetPins && star.isEmpty && unstar.isEmpty { return nil }
        return PinSyncPlan(source: source.id, newPins: list, star: star, unstar: unstar, seenPins: targetPins)
    }

    /// Writes the list, then the records. Nothing is written when the target is open, the
    /// pin list on disk is no longer what the plan saw, or the config cannot be parsed.
    public static func apply(_ plan: PinSyncPlan, to target: Profile, transfer: ChatTransfer, openFolders: [URL]) throws {
        let targetPath = target.path.resolvingSymlinksInPath().standardizedFileURL.path
        if openFolders.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == targetPath }) {
            throw SwitcherError(L("The profile is open; pins were not synced.", "Profil açık; pinler eşitlenmedi."), logReason: "profile is open")
        }
        guard transfer.pins(of: target) == plan.seenPins else {
            throw SwitcherError(L("The pins changed since they were read; pins were not synced.", "Pinler okunduktan sonra değişti; eşitlenmedi."),
                                logReason: "pins changed since planning")
        }
        // Records-only repair: the list is already right, so the config is not rewritten (and not backed up).
        if plan.newPins != plan.seenPins { try transfer.writePins(plan.newPins, to: target, openFolders: openFolders) }
        // The list is written; every record is tried, failures are reported once at the end.
        let failed = transfer.setStarred(true, ids: plan.star, in: target) + transfer.setStarred(false, ids: plan.unstar, in: target)
        if failed > 0 {
            throw SwitcherError(L("The pin list was written, but \(failed) chat record(s) could not be updated; the next pin sync into this account retries.",
                                  "Pin listesi yazıldı, ancak \(failed) sohbet kaydı güncellenemedi; bu hesaba bir sonraki pin eşitlemesinde yeniden denenir."),
                                logReason: "\(failed) record(s) not updated")
        }
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
