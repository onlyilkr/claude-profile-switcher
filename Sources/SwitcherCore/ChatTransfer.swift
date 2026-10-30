import Foundation

/*
    The desktop app keeps one small JSON record per Claude Code chat, at
        <profile>/claude-code-sessions/<account>/<organisation>/local_<id>.json
    and the transcript itself in ~/.claude/projects, shared by every profile. Copying a
    chat to another account places that record in the other profile's store.

    The rules follow claude-migrate (github.com/onlyilkr/claude-migrate), which worked them
    out against real stores: keep the id and every field, empty bridgeSessionIds and drop
    scheduledTaskId (both belong to the old account), never overwrite, never bring back a
    chat the target deleted, and never write while the target is open, because Claude
    writes its in-memory list back when it quits.
*/

public struct CodeSession: Identifiable, Equatable {
    public var id: String { file.lastPathComponent }
    public let file: URL
    /// local_<sessionID>.json
    public let sessionID: String
    public let cliSessionID: String
    public let priorCLISessionIDs: [String]
    public let title: String
    public let folder: String
    public let updated: Date
    public let hasTranscript: Bool
    /// The record's worktreePath, when the chat runs in a git worktree (nil if absent or empty).
    public var worktreePath: String? = nil
    /// local_<id> of the chat this one was spawned from, unless the record says the lineage is detached.
    public var parentID: String? = nil
}

public struct TargetStore {
    public let dir: URL
    var cliIDs: Set<String>
    var fileNames: Set<String>
    var deleted: Set<String>
    /// How many organisation stores the signed-in account has; above one, the one with the
    /// most recent chat was picked.
    public var organisationCount = 1

    /// Whether the store holds a record under this file name (local_<id>.json).
    public func has(_ fileName: String) -> Bool { fileNames.contains(fileName) }
}

public enum TransferOutcome: Equatable {
    case copied, alreadyThere, deletedInTarget, nameConflict, noCLISession
    case failed(String)
}

public struct ChatTransfer {
    public let transcriptsRoot: URL

    public init(transcriptsRoot: URL) { self.transcriptsRoot = transcriptsRoot }

    public static func sessionRoot(_ profile: Profile) -> URL {
        profile.path.appendingPathComponent("claude-code-sessions", isDirectory: true)
    }

    /// cliSessionIds with a transcript on disk. A record without one opens empty.
    public func transcriptIndex() -> Set<String> {
        let fm = FileManager.default
        var ids = Set<String>()
        for project in subdirectories(transcriptsRoot) {
            for name in (try? fm.contentsOfDirectory(atPath: project.path)) ?? [] where name.hasSuffix(".jsonl") {
                ids.insert(String(name.dropLast(".jsonl".count)))
            }
        }
        return ids
    }

    /// Every chat in the profile, newest first. A chat sitting under two accounts after an
    /// earlier copy is listed once; one the user deleted is not listed.
    public func sessions(in profile: Profile) -> [CodeSession] {
        let transcripts = transcriptIndex()
        var byName: [String: CodeSession] = [:]
        for account in subdirectories(ChatTransfer.sessionRoot(profile)) {
            for org in subdirectories(account) {
                let deleted = deletedMarkers(in: org)
                for file in records(in: org) {
                    guard let raw = readObject(file) else { continue }
                    let session = makeSession(file: file, raw: raw, transcripts: transcripts)
                    if deleted.contains(session.sessionID) { continue }
                    if let seen = byName[session.id], seen.updated >= session.updated { continue }
                    byName[session.id] = session
                }
            }
        }
        return byName.values.sorted { $0.updated > $1.updated }
    }

    /// The store of the account the profile is signed in to, as config.json last recorded
    /// it, and within it the organisation with the most recent chat. nil until that account
    /// has opened the Code tab once: a store of an account signed in earlier would take the
    /// chats but never show them.
    public func targetStore(for profile: Profile) -> TargetStore? {
        let accounts = subdirectories(ChatTransfer.sessionRoot(profile))
        let account: URL?
        if let last = SignInState.lastAccount(profileDir: profile.path) {
            account = accounts.first { $0.lastPathComponent == last }
        } else {
            account = accounts.count == 1 ? accounts[0] : accounts.max { lastActivity($0) < lastActivity($1) }
        }
        let orgs = account.map(subdirectories) ?? []
        guard let org = orgs.max(by: { lastActivity($0) < lastActivity($1) }) else { return nil }
        var store = TargetStore(dir: org, cliIDs: [], fileNames: [], deleted: deletedMarkers(in: org))
        store.organisationCount = orgs.count
        for name in (try? FileManager.default.contentsOfDirectory(atPath: org.path)) ?? [] where name.hasPrefix("local_") {
            store.fileNames.insert(name)
        }
        for file in records(in: org) {
            guard let raw = readObject(file) else { continue }
            for id in [raw["cliSessionId"] as? String].compactMap({ $0 }) + ((raw["priorCliSessionIds"] as? [String]) ?? []) where !id.isEmpty {
                store.cliIDs.insert(id)
            }
        }
        return store
    }

    public func copy(_ session: CodeSession, to store: inout TargetStore) -> TransferOutcome {
        if session.cliSessionID.isEmpty { return .noCLISession }
        if store.cliIDs.contains(session.cliSessionID) || session.priorCLISessionIDs.contains(where: store.cliIDs.contains) {
            return .alreadyThere
        }
        if store.deleted.contains(session.sessionID) { return .deletedInTarget }
        if store.fileNames.contains(session.id) { return .nameConflict }
        guard let raw = readObject(session.file) else { return .failed(L("could not read the chat", "sohbet okunamadı")) }
        do {
            let data = try JSONSerialization.data(withJSONObject: ChatTransfer.transform(raw), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try ChatTransfer.writeNew(data, to: store.dir.appendingPathComponent(session.id))
        } catch let error as SwitcherError where error.message == "exists" {
            return .nameConflict
        } catch {
            return .failed(error.localizedDescription)
        }
        store.fileNames.insert(session.id)
        store.cliIDs.insert(session.cliSessionID)
        return .copied
    }

    // MARK: Parent chats

    /// local_<id> of the chats the target account has, and of those it deleted (both name forms).
    public struct TargetChats {
        public let ids: Set<String>
        public let deleted: Set<String>
    }

    public func targetChats(of target: Profile) -> TargetChats {
        var deleted = Set<String>()
        for account in subdirectories(ChatTransfer.sessionRoot(target)) {
            for org in subdirectories(account) {
                for marker in deletedMarkers(in: org) {
                    deleted.insert(marker.hasPrefix("local_") ? marker : "local_" + marker)
                }
            }
        }
        return TargetChats(ids: chatIDs(in: target), deleted: deleted)
    }

    /// The parents (and their parents) of `picked` that the target lacks, farthest ancestor first,
    /// without the picked chats themselves. Claude shows a sub-session under its parent only when
    /// the whole chain up to a chat it knows is there. The walk stops at the first ancestor the
    /// target has, one `all` does not list, one the target deleted (never revived), a cycle, or
    /// after 32 steps. `all` is the source's sessions, so nothing is read from disk.
    public func missingAncestors(of picked: [CodeSession], among all: [CodeSession], target: TargetChats) -> [CodeSession] {
        let byID = Dictionary(all.map { ("local_" + $0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        let pickedIDs = Set(picked.map { "local_" + $0.sessionID })
        var found: [String] = []
        var seenIDs = Set<String>()
        for chat in picked {
            var chain: [String] = []
            var visited: Set<String> = ["local_" + chat.sessionID]
            var next = chat.parentID
            var steps = 0
            while let id = next, steps < 32 {
                steps += 1
                if !visited.insert(id).inserted || target.ids.contains(id) || target.deleted.contains(id) { break }
                guard let parent = byID[id] else { break }
                if !pickedIDs.contains(id) { chain.append(id) }
                next = parent.parentID
            }
            // Collected nearest first; the copy list wants the farthest first.
            for id in chain.reversed() where seenIDs.insert(id).inserted { found.append(id) }
        }
        return found.compactMap { byID[$0] }
    }

    public func missingAncestors(of picked: [CodeSession], from source: Profile, to target: Profile) -> [CodeSession] {
        missingAncestors(of: picked, among: sessions(in: source), target: targetChats(of: target))
    }

    // MARK: Pins

    /// Pins are one ordered list of local_<id> values per profile, in its
    /// claude_desktop_config.json. Within one profile every account shares it (which is why
    /// claude-migrate keeps pins by keeping ids); across profiles each has its own.
    static let pinsPath = ["preferences", "epitaxyPrefs", "starred-local-code-sessions"]

    public static func configFile(_ profile: Profile) -> URL {
        profile.path.appendingPathComponent("claude_desktop_config.json")
    }

    public func pins(of profile: Profile) -> [String] {
        guard let root = readObject(ChatTransfer.configFile(profile)) else { return [] }
        var node: Any? = root
        for key in ChatTransfer.pinsPath { node = (node as? [String: Any])?[key] }
        return (node as? [String]) ?? []
    }

    /// Pins the copied `sessions` that are pinned in `source` at the top of `target`'s sidebar, in
    /// the source's sidebar order; the target's other pins follow. Written to Claude's own pin store
    /// (closed account, backed up, verified), then to the mirrors: the config's pin list and
    /// isStarred on the records. Mirror failures are ignored, as Claude rewrites them from its store
    /// when it starts. Returns how many were carried; a source without a readable pin record carries
    /// nothing. Throws when the target is open or the store refuses; the copied chats stay.
    @discardableResult
    public func carryPins(of sessions: [CodeSession], from source: Profile, to target: Profile, openFolders: [URL] = [], backups: URL) throws -> Int {
        let wanted = Set(sessions.map { "local_\($0.sessionID)" })
        // The source may be open, so its files can end in a half-written entry.
        guard let sourcePins = (try? ClaudePinStore.read(source, tolerateTornTail: true)) ?? nil else { return 0 }
        var seen = Set<String>()
        let carried = sourcePins.sidebar.filter { wanted.contains($0) && seen.insert($0).inserted }
        guard !carried.isEmpty else { return 0 }

        if openFolders.contains(where: { ProfileStore.sameItem($0, target.path) }) {
            throw SwitcherError(L("The profile is open; pins were not carried over.", "Profil açık; pinler taşınmadı."), logReason: "profile is open")
        }
        guard let targetPins = try ClaudePinStore.read(target, tolerateTornTail: false) else { throw PinSync.noPinRecord(target) }
        let list = carried + targetPins.sidebar.filter { !seen.contains($0) }
        _ = try ClaudePinStore.write(list, to: target, backups: backups)

        if pins(of: target) != list { try? writePins(list, to: target, openFolders: openFolders) }
        _ = setStarred(true, ids: carried, in: target)
        return carried.count
    }

    /// Replaces the pin list in `target`'s claude_desktop_config.json, keeping every other key.
    /// Writes through a symlink to the real file, refuses when that file belongs to an open
    /// profile or cannot be parsed, keeps a dated backup first, then writes atomically (0600).
    /// `afterwards` is appended to the user-visible refusal messages.
    public func writePins(_ list: [String], to target: Profile, openFolders: [URL] = [], afterwards: String = "") throws {
        // Through a symlink to the real file: a profile may share Default's config that way,
        // and an atomic write to the link itself would replace the link with a copy.
        let file = ChatTransfer.configFile(target).resolvingSymlinksInPath()
        // A shared (symlinked) config may live in another profile; that one must be closed
        // too, or its Claude writes the old list back over the change when it quits.
        let real = file.standardizedFileURL.path
        if let owner = openFolders.first(where: { ProfileStore.isInside(file, $0) }) {
            throw SwitcherError(L("The pins live in \(real), which belongs to the open profile at \(owner.path). Quit it and try again.\(afterwards)",
                                  "Pinler \(real) dosyasında, o da \(owner.path) konumundaki açık profile ait. Onu kapatıp tekrar deneyin.\(afterwards)"),
                                logReason: "config belongs to an open profile")
        }
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            // Unreadable means a hand edit went wrong, not "empty": writing would wipe the
            // MCP servers and every other setting in it.
            guard let parsed = readObject(file) else {
                throw SwitcherError(L("\(file.path) is not valid JSON, so the pins were not written.\(afterwards)",
                                      "\(file.path) geçerli bir JSON değil, bu yüzden pinler yazılmadı.\(afterwards)"),
                                      logReason: "config is not valid JSON")
            }
            root = parsed
        }
        // A present value of the wrong type is a hand edit gone wrong; replacing it with a fresh
        // object would silently drop what was there. Checked before the backup: nothing is written.
        func unexpected(_ key: String) -> SwitcherError {
            SwitcherError(L("\(file.path) has an unexpected '\(key)' value, so the pins were not written.\(afterwards)",
                            "\(file.path) içindeki '\(key)' değeri beklenen biçimde değil, bu yüzden pinler yazılmadı.\(afterwards)"),
                          logReason: "config has an unexpected shape")
        }
        var preferences: [String: Any] = [:]
        if let value = root["preferences"] {
            guard let object = value as? [String: Any] else { throw unexpected("preferences") }
            preferences = object
        }
        var epitaxy: [String: Any] = [:]
        if let value = preferences["epitaxyPrefs"] {
            guard let object = value as? [String: Any] else { throw unexpected("epitaxyPrefs") }
            epitaxy = object
        }
        if FileManager.default.fileExists(atPath: file.path) { try ChatTransfer.backUp(file) }
        epitaxy["starred-local-code-sessions"] = list
        preferences["epitaxyPrefs"] = epitaxy
        root["preferences"] = preferences
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }

    /// A dated copy next to the file, never replacing an earlier one; the newest five are kept.
    static func backUp(_ file: URL) throws {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        let base = file.lastPathComponent + ".switcher-backup-"
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var n = 0
        while true {
            let name = base + String(stamp) + (n == 0 ? "" : "-\(n)")
            do {
                try fm.copyItem(at: file, to: dir.appendingPathComponent(name))
                break
            } catch CocoaError.fileWriteFileExists {
                n += 1
            }
        }
        let backups = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(base) }
        for old in backups.sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending }).dropFirst(5) {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
    }

    /// A copy with the account-bound fields reset; every other field keeps its value, the
    /// session id included.
    public static func transform(_ raw: [String: Any]) -> [String: Any] {
        var out = raw
        out["bridgeSessionIds"] = [Any]()
        out.removeValue(forKey: "scheduledTaskId")
        return out
    }

    /// Written to a temp file, then hard-linked into place: link(2) fails if the name
    /// exists, so an existing file is never replaced, even by a racing writer.
    public static func writeNew(_ data: Data, to final: URL) throws {
        let temp = final.deletingLastPathComponent().appendingPathComponent(".claude-profile-switcher-\(UUID().uuidString).tmp")
        try data.write(to: temp)
        defer { unlink(temp.path) }
        chmod(temp.path, 0o600)
        if link(temp.path, final.path) != 0 {
            if errno == EEXIST { throw SwitcherError("exists") }
            throw SwitcherError(String(cString: strerror(errno)))
        }
    }

    // MARK: Helpers

    func makeSession(file: URL, raw: [String: Any], transcripts: Set<String>) -> CodeSession {
        let base = file.deletingPathExtension().lastPathComponent
        let sessionID = String(base.dropFirst("local_".count))
        let cli = (raw["cliSessionId"] as? String) ?? ""
        var title = ((raw["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Chat \(sessionID.prefix(8))" }
        let cwd = (raw["cwd"] as? String) ?? ""
        let folder = cwd.isEmpty ? "" : (cwd.contains("/scratch-workspaces/") ? L("(no folder)", "(klasör yok)") : URL(fileURLWithPath: cwd).lastPathComponent)
        var updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let ms = raw["lastActivityAt"] as? NSNumber, ms.doubleValue > 0 { updated = Date(timeIntervalSince1970: ms.doubleValue / 1000) }
        return CodeSession(file: file, sessionID: sessionID, cliSessionID: cli,
                           priorCLISessionIDs: (raw["priorCliSessionIds"] as? [String]) ?? [],
                           title: title, folder: folder, updated: updated,
                           hasTranscript: !cli.isEmpty && transcripts.contains(cli),
                           worktreePath: (raw["worktreePath"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                           parentID: (raw["lineageDetached"] as? Bool) == true ? nil
                               : ((raw["spawnedFrom"] as? [String: Any])?["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    func subdirectories(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    func records(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// Claude leaves deleted_<id> (or deleted_<id>.json) behind for a chat the user deleted.
    func deletedMarkers(in dir: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { $0.hasPrefix("deleted_") }.map { name in
            var id = String(name.dropFirst("deleted_".count))
            if id.hasSuffix(".json") { id = String(id.dropLast(".json".count)) }
            return id
        })
    }

    func readObject(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// When a store was last used: its newest chat record. A folder's own date moves for
    /// unrelated reasons (Claude's markers, Finder), so it only counts when there are none.
    func lastActivity(_ dir: URL) -> Date {
        let fm = FileManager.default
        let records = subdirectories(dir).flatMap(records(in:)) + records(in: dir)
        let dates = records.compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        if let newest = dates.max() { return newest }
        return (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date ?? .distantPast
    }
}
