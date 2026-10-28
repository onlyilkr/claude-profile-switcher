import Foundation

public struct LinkReport: Equatable {
    /// profileIDs now using the winner's folder and history.
    public var linked: [String]
    /// profileID -> reason
    public var skipped: [String: String]
    /// profileID -> note for an account that is linked but needs a look (its old history file was left in place).
    public var warnings: [String: String]
    public init(linked: [String] = [], skipped: [String: String] = [:], warnings: [String: String] = [:]) {
        self.linked = linked; self.skipped = skipped; self.warnings = warnings
    }
}

public struct UnlinkReport: Equatable {
    public var removed: Int
    public var skipped: [String]
    public init(removed: Int = 0, skipped: [String] = []) { self.removed = removed; self.skipped = skipped }
}

/// Makes every copy of a chat use one folder (and so one history file) by pointing the other
/// accounts' records at the winner's worktree and leasing that worktree to the chat there.
/// Everything it changes in a lease file is written to the ledger so it can be undone.
public struct ChatLinker {
    public typealias Live = () -> [(pid: pid_t, profileDir: String, cliSessionID: String)]

    private let paths: Paths
    private let ledger: LinksLedger
    private let live: Live
    private let openFolders: () -> [URL]

    public init(paths: Paths, ledger: LinksLedger, live: @escaping Live = ProcessScanner.liveCLISessions, openFolders: @escaping () -> [URL]) {
        self.paths = paths; self.ledger = ledger; self.live = live; self.openFolders = openFolders
    }

    // MARK: Helpers

    private static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private func isOpen(_ profile: Profile) -> Bool {
        let mine = ChatLinker.canonical(profile.path)
        return openFolders().contains { ChatLinker.canonical($0) == mine }
    }

    /// The same file or folder: equal after resolving symlinks, or (both existing) the same device and inode,
    /// which also catches a different spelling of the same folder on a case-insensitive volume.
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        if a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path { return true }
        let fm = FileManager.default
        guard let x = try? fm.attributesOfItem(atPath: a.path), let y = try? fm.attributesOfItem(atPath: b.path),
              let xi = x[.systemFileNumber] as? NSNumber, let yi = y[.systemFileNumber] as? NSNumber,
              let xd = x[.systemNumber] as? NSNumber, let yd = y[.systemNumber] as? NSNumber else { return false }
        return xi == yi && xd == yd
    }

    private static func norm(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func json(_ value: Any) -> Data? {
        JSONSerialization.isValidJSONObject(value) ? try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) : nil
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func entries(_ root: [String: Any]) -> [String: Any] { (root["worktrees"] as? [String: Any]) ?? [:] }

    private static let missingLease = L("Claude doesn't keep a worktree list in this account yet; open one chat that uses a worktree in it once.",
                                        "Claude bu hesapta henüz worktree kaydı tutmuyor; bu hesapta bir kez worktree'li bir sohbet açın.")

    private static func leaseProblem(_ read: WorktreeLeases.Read) -> String? {
        switch read {
        case .ok: return nil
        case .missing: return missingLease
        case .unreadable: return L("Claude's worktree list in this account can't be read.", "Claude'un bu hesaptaki worktree listesi okunamadı.")
        case .unsupported: return L("Claude's worktree list in this account has a version this tool doesn't know.", "Claude'un bu hesaptaki worktree listesi bu aracın tanımadığı bir sürümde.")
        }
    }

    /// The ledger records for the entries that differ between `before` and `after`.
    private func diff(profile: Profile, session: String, before: [String: Any], after: [String: Any], released: [String], added: String?) -> [LinkRecord] {
        let old = ChatLinker.entries(before), new = ChatLinker.entries(after)
        var out: [LinkRecord] = []
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // the ledger stores whole seconds; keeps in-memory records equal to stored ones
        for name in released {
            guard let w = new[name], let written = ChatLinker.json(w) else { continue }
            out.append(LinkRecord(profileID: profile.id, entryName: name, action: "released", previous: old[name].flatMap(ChatLinker.json),
                                  written: written, at: now, sessionID: session))
        }
        if let added, let w = new[added], let written = ChatLinker.json(w) {
            let prior = old[added].flatMap(ChatLinker.json)
            if prior != written {
                out.append(LinkRecord(profileID: profile.id, entryName: added, action: "added", previous: prior, written: written, at: now, sessionID: session))
            }
        }
        return out
    }

    // MARK: link

    private struct Plan {
        let profile: Profile
        let copy: ChatCopy
        let loserRaw: [String: Any]
        let loserRoot: [String: Any]?
        let alreadyLinked: Bool
    }

    /// `expectedForks`: profileID -> the number of messages of its own that a copy the user picked to
    /// replace had when the chat was checked; such a forked copy is only replaced while it still has them.
    public func link(_ chat: SharedChat, winner: String, profiles: [Profile], expectedForks: [String: Int] = [:]) throws -> LinkReport {
        guard let win = chat.copies.first(where: { $0.profileID == winner }) else {
            throw SwitcherError(L("The chat has no copy in that account.", "Sohbetin bu hesapta kopyası yok."))
        }
        // A live process keeps the history in memory and writes it back: refuse the whole call.
        if live().contains(where: { $0.cliSessionID == chat.cliSessionID }) {
            throw SwitcherError(L("This chat is still running in Claude. Quit Claude in every account and try again.",
                                  "Bu sohbet Claude'da hâlâ çalışıyor. Tüm hesaplarda Claude'u kapatıp tekrar deneyin."))
        }
        let transfer = ChatTransfer(transcriptsRoot: paths.transcriptsRoot)
        guard let winnerRaw = transfer.readObject(win.record) else {
            throw SwitcherError(L("The chat's record in the winning account can't be read.", "Sohbetin kazanan hesaptaki kaydı okunamadı."))
        }
        guard (winnerRaw["cliSessionId"] as? String) == chat.cliSessionID else {
            throw SwitcherError(L("The record in the winning account points at a different history.", "Kazanan hesaptaki kayıt farklı bir geçmişe işaret ediyor."))
        }
        let winnerPath = win.worktreePath
        var winnerEntry: (name: String, value: [String: Any])?
        if let winnerPath {
            guard let winnerProfile = profiles.first(where: { $0.id == winner }), case .ok(let wroot) = WorktreeLeases.read(winnerProfile),
                  let e = WorktreeLeases.entry(leasedTo: chat.id, path: winnerPath, in: wroot) else {
                throw SwitcherError(L("The winning account doesn't hold the worktree lease for this chat.", "Kazanan hesap bu sohbet için worktree kirasını tutmuyor."))
            }
            winnerEntry = e
        }

        var report = LinkReport()
        var plans: [Plan] = []
        for copy in chat.copies where copy.profileID != winner {
            guard let profile = profiles.first(where: { $0.id == copy.profileID }) else {
                report.skipped[copy.profileID] = L("The account is not known.", "Hesap bilinmiyor."); continue
            }
            if isOpen(profile) {
                report.skipped[copy.profileID] = L("Claude is open in this account. Quit it and try again.", "Bu hesapta Claude açık. Kapatıp tekrar deneyin."); continue
            }
            guard let loserRaw = transfer.readObject(copy.record) else {
                report.skipped[copy.profileID] = L("The chat's record can't be read.", "Sohbet kaydı okunamadı."); continue
            }
            guard (loserRaw["cliSessionId"] as? String) == chat.cliSessionID else {
                report.skipped[copy.profileID] = L("The record points at a different history.", "Kayıt farklı bir geçmişe işaret ediyor."); continue
            }
            var loserRoot: [String: Any]?
            if winnerEntry != nil {
                let read = WorktreeLeases.read(profile)
                if let why = ChatLinker.leaseProblem(read) { report.skipped[copy.profileID] = why; continue }
                if case .ok(let r) = read { loserRoot = r }
            }
            let sameCwd = ChatLinker.norm(copy.cwd) == ChatLinker.norm(win.cwd)
                || ChatLinker.sameItem(URL(fileURLWithPath: copy.cwd), URL(fileURLWithPath: win.cwd))
            let held = winnerPath == nil || loserRoot.map { WorktreeLeases.holder(of: winnerPath!, in: $0) == chat.id } == true
            let already = sameCwd && held
            if !already && !win.hasTranscript {
                report.skipped[copy.profileID] = L("The winning copy has no history file to share.", "Kazanan kopyanın paylaşılacak geçmiş dosyası yok."); continue
            }
            plans.append(Plan(profile: profile, copy: copy, loserRaw: loserRaw, loserRoot: loserRoot, alreadyLinked: already))
        }

        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        // Pass 1: re-check every account right before anything is written, so the set of accounts that
        // will definitely be relinked is known before the first file moves (no dependence on loop order).
        var ready: [Plan] = []
        for plan in plans {
            if plan.alreadyLinked { report.linked.append(plan.profile.id); continue }
            if isOpen(plan.profile) {
                report.skipped[plan.profile.id] = L("Claude is open in this account. Quit it and try again.", "Bu hesapta Claude açık. Kapatıp tekrar deneyin."); continue
            }
            if live().contains(where: { $0.cliSessionID == chat.cliSessionID }) {
                report.skipped[plan.profile.id] = L("This chat is still running in Claude. Quit Claude in every account and try again.",
                                                    "Bu sohbet Claude'da hâlâ çalışıyor. Tüm hesaplarda Claude'u kapatıp tekrar deneyin."); continue
            }
            // The scan may be old: the loser's history must still be behind the winner's (or, for a fork the
            // user picked, still have just the messages the scan showed).
            if !ChatLinker.sameItem(plan.copy.transcript, win.transcript), FileManager.default.fileExists(atPath: plan.copy.transcript.path) {
                var fine = false
                switch try? TranscriptDiff.compare(win.transcript, plan.copy.transcript) {
                case .some(.identical), .some(.firstAhead): fine = true
                case .some(.forked(_, let own)): fine = expectedForks[plan.profile.id] == own
                default: fine = false
                }
                if !fine { report.skipped[plan.profile.id] = ChatLinker.staleMessage; continue }
            }
            ready.append(plan)
        }
        // Accounts that end up on the winner's folder: already there, or about to be written.
        let relinked = Set(plans.map(\.profile.id)).subtracting(report.skipped.keys)
        // Pass 2: write.
        for plan in ready {
            do {
                // Another copy that is not being relinked and uses the same history file keeps it.
                let shared = chat.copies.contains { other in
                    other.profileID != plan.profile.id && other.profileID != win.profileID && other.hasTranscript
                        && (!relinked.contains(other.profileID) || report.skipped[other.profileID] != nil)
                        && ChatLinker.sameItem(other.transcript, plan.copy.transcript)
                }
                try backUpWorktreeList(of: plan.profile, stamp: stamp)
                let warning = try apply(plan, chat: chat, win: win, winnerRaw: winnerRaw, winnerEntry: winnerEntry, transfer: transfer,
                                        stamp: stamp, keepTranscript: shared)
                report.linked.append(plan.profile.id)
                if let warning { report.warnings[plan.profile.id] = warning }
            } catch {
                report.skipped[plan.profile.id] = error.localizedDescription
            }
        }
        return report
    }

    private static let staleMessage = L("This chat changed since it was checked; refresh and try again.",
                                        "Bu sohbet kontrol edildikten sonra değişti; yenileyip tekrar deneyin.")

    /// Copies the account's `git-worktrees.json` next to the history backups before anything is written.
    /// Never rotated; nothing is written when it can't be copied.
    private func backUpWorktreeList(of profile: Profile, stamp: String) throws {
        let source = WorktreeLeases.file(profile).resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: source) else { return }
        let dir = backupFolder(stamp: stamp, profileID: profile.id)
        try prepare(dir)
        var dest = dir.appendingPathComponent("git-worktrees.json")
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) { dest = dir.appendingPathComponent("git-worktrees.json-\(n)"); n += 1 }
        try data.write(to: dest)
        chmod(dest.path, 0o600)
    }

    private func backupFolder(stamp: String, profileID: String) -> URL {
        let safeID = profileID.replacingOccurrences(of: "/", with: "_")
        return paths.switcherHome.appendingPathComponent("backups", isDirectory: true).appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true).appendingPathComponent(safeID, isDirectory: true)
    }

    private func prepare(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for d in [dir.deletingLastPathComponent(), dir] { chmod(d.path, 0o700) }
    }

    /// Returns a warning when the account is linked but its old history file could not be (or was not) moved.
    @discardableResult
    private func apply(_ plan: Plan, chat: SharedChat, win: ChatCopy, winnerRaw: [String: Any],
                       winnerEntry: (name: String, value: [String: Any])?, transfer: ChatTransfer,
                       stamp: String, keepTranscript: Bool) throws -> String? {
        // 0. A ledger that can't be read means nothing is written for this account.
        try ledger.ensureReadable()
        // 1. Lease steps (the step that can be refused because Claude changed the file; nothing
        //    else has been touched yet). The ledger entries go in first: a record for a change
        //    that never landed is harmless, an unrecorded change is not.
        var leaseUndo: (original: [String: Any], written: [String: Any])?
        var records: [LinkRecord] = []
        if let winnerEntry, let winnerPath = win.worktreePath, let original = plan.loserRoot {
            var root = original
            var released: [String] = []
            let wanted = ChatLinker.norm(winnerPath)
            for (key, raw) in ChatLinker.entries(original) {
                guard let v = raw as? [String: Any], v["leasedBy"] as? String == chat.id else { continue }
                if let p = v["path"] as? String, ChatLinker.norm(p) == wanted { continue }
                root = WorktreeLeases.releasing(name: key, from: root)
                released.append(key)
            }
            root = try WorktreeLeases.adding(winnerEntry, for: chat.id, to: root)
            if !NSDictionary(dictionary: root).isEqual(to: original) {
                records = diff(profile: plan.profile, session: chat.id, before: original, after: root, released: released, added: winnerEntry.name)
                if !records.isEmpty { try ledger.append(records) }
                do { try WorktreeLeases.write(root, basedOn: original, to: plan.profile) } catch {
                    try? ledger.remove(where: { records.contains($0) })
                    throw error
                }
                leaseUndo = (original, root)
            }
        }
        // 2. Record: the winner's, keeping this account's own archive and star state.
        do {
            var new = ChatTransfer.transform(winnerRaw)
            for key in ["isArchived", "isStarred"] {
                if let v = plan.loserRaw[key] { new[key] = v } else { new.removeValue(forKey: key) }
            }
            let data = try JSONSerialization.data(withJSONObject: new, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try writeRecord(data, to: plan.copy.record)
        } catch {
            // Put the lease file back as it was, so the account is not left half linked.
            var note = ""
            if let undo = leaseUndo {
                do { try WorktreeLeases.write(undo.original, basedOn: undo.written, to: plan.profile) } catch {
                    note = " " + L("The worktree list could not be restored; Undo linking will remove the added entry.",
                                   "Worktree listesi geri yüklenemedi; Bağı kaldır eklenen girişi silecek.")
                    throw SwitcherError(error.localizedDescription + note)
                }
                try? ledger.remove(where: { records.contains($0) })
            }
            throw error
        }
        // 3. History: this account's own copy goes to the backup folder, never deleted, and only
        //    when it is not the file the winner uses (same path or same device and inode).
        if !ChatLinker.sameItem(plan.copy.transcript, win.transcript) {
            if keepTranscript {
                return L("Its old history file was kept where it is: another account's copy still uses it.",
                         "Eski geçmiş dosyası yerinde bırakıldı: başka bir hesabın kopyası hâlâ onu kullanıyor.")
            }
            do { try moveToBackup(plan.copy, cli: chat.cliSessionID, profileID: plan.profile.id, stamp: stamp) } catch {
                return L("Linked, but its old history file could not be moved: \(error.localizedDescription)",
                         "Bağlandı, ama eski geçmiş dosyası taşınamadı: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func writeRecord(_ data: Data, to record: URL) throws {
        let real = record.resolvingSymlinksInPath()
        try ChatTransfer.backUp(real)
        let temp = real.deletingLastPathComponent().appendingPathComponent(".claude-profile-switcher-\(UUID().uuidString).tmp")
        try data.write(to: temp)
        chmod(temp.path, 0o600)
        if rename(temp.path, real.path) != 0 {
            let message = String(cString: strerror(errno))
            Darwin.unlink(temp.path)
            throw SwitcherError(message)
        }
    }

    private func moveToBackup(_ copy: ChatCopy, cli: String, profileID: String, stamp: String) throws {
        let fm = FileManager.default
        let sources = [copy.transcript,
                       TranscriptLocator.sidecar(root: paths.transcriptsRoot, cwd: copy.cwd, cliSessionID: cli)].filter { fm.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return }
        let dir = backupFolder(stamp: stamp, profileID: profileID)
        try prepare(dir)
        for src in sources {
            var dest = dir.appendingPathComponent(src.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: dest.path) { dest = dir.appendingPathComponent("\(src.lastPathComponent)-\(n)"); n += 1 }
            try fm.moveItem(at: src, to: dest)
        }
    }

    // MARK: bindOnTransfer

    /// Transfer-time variant: only leases the worktree to the chat in `to`. nil = done (or nothing to do).
    public func bindOnTransfer(session: CodeSession, from: Profile, to: Profile) -> String? {
        guard let path = session.worktreePath else { return nil }
        let id = "local_" + session.sessionID
        if isOpen(to) { return L("Claude is open in this account. Quit it and try again.", "Bu hesapta Claude açık. Kapatıp tekrar deneyin.") }
        // The target already has its own copy of this chat in another folder: it has its own history, which
        // binding would orphan. Sync (which backs it up) is the way.
        let transfer = ChatTransfer(transcriptsRoot: paths.transcriptsRoot)
        if let sourceCwd = transfer.readObject(session.file)?["cwd"] as? String {
            for account in transfer.subdirectories(ChatTransfer.sessionRoot(to)) {
                for org in transfer.subdirectories(account) {
                    for file in transfer.records(in: org) {
                        guard let raw = transfer.readObject(file), file.deletingPathExtension().lastPathComponent == id || raw["sessionId"] as? String == id,
                              let cwd = raw["cwd"] as? String, !cwd.isEmpty else { continue }
                        if !ChatLinker.sameItem(URL(fileURLWithPath: cwd), URL(fileURLWithPath: sourceCwd)) {
                            return L("The copy in this account has its own history; use Sync in Shared chats.",
                                     "Bu hesaptaki kopyanın kendi geçmişi var; Ortak sohbetler'deki Eşitle'yi kullanın.")
                        }
                    }
                }
            }
        }
        let notInSource = L("This chat's worktree isn't in '\(from.name)'s worktree list, so it was copied without linking.",
                            "Bu sohbetin worktree'si '\(from.name)' hesabının worktree listesinde yok; bağlanmadan kopyalandı.")
        guard case .ok(let sroot) = WorktreeLeases.read(from), let entry = WorktreeLeases.entry(leasedTo: id, path: path, in: sroot) else {
            return notInSource
        }
        let target = WorktreeLeases.read(to)
        if let why = ChatLinker.leaseProblem(target) { return why }
        guard case .ok(let original) = target else { return ChatLinker.leaseProblem(target) }
        do {
            let root = try WorktreeLeases.adding(entry, for: id, to: original)
            if NSDictionary(dictionary: root).isEqual(to: original) { return nil }
            try ledger.ensureReadable()
            let records = diff(profile: to, session: id, before: original, after: root, released: [], added: entry.name)
            if !records.isEmpty { try ledger.append(records) }
            do { try WorktreeLeases.write(root, basedOn: original, to: to) } catch {
                try? ledger.remove(where: { records.contains($0) })
                throw error
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: unlink

    public func unlink(sessionID: String?, profiles: [Profile]) -> UnlinkReport {
        var report = UnlinkReport()
        let all = ledger.records().filter { sessionID == nil || $0.sessionID == sessionID }
        var handled: [LinkRecord] = []
        for record in all where record.action == "added" {
            guard let profile = profiles.first(where: { $0.id == record.profileID }) else {
                report.skipped.append(L("\(record.profileID): the account is not known.", "\(record.profileID): hesap bilinmiyor.")); continue
            }
            if isOpen(profile) {
                report.skipped.append(L("\(profile.name): Claude is open in this account.", "\(profile.name): bu hesapta Claude açık.")); continue
            }
            guard case .ok(let original) = WorktreeLeases.read(profile) else {
                report.skipped.append(L("\(profile.name): the worktree list can't be read.", "\(profile.name): worktree listesi okunamadı.")); continue
            }
            var wts = ChatLinker.entries(original)
            guard let current = wts[record.entryName] else { handled.append(record); continue }
            guard let w = ChatLinker.object(record.written), NSDictionary(dictionary: w).isEqual(to: current) else {
                report.skipped.append(L("\(profile.name): \(record.entryName) changed since it was linked.", "\(profile.name): \(record.entryName) bağlandıktan sonra değişmiş.")); continue
            }
            wts.removeValue(forKey: record.entryName)
            var root = original
            root["worktrees"] = wts
            do {
                try WorktreeLeases.write(root, basedOn: original, to: profile)
                report.removed += 1
                handled.append(record)
            } catch {
                report.skipped.append("\(profile.name): \(error.localizedDescription)")
            }
        }
        // Released leases are not restored; their records go once no link of that chat is left.
        let stillAdded = Set(all.filter { $0.action == "added" && !handled.contains($0) }.map(\.sessionID))
        let drop = handled + all.filter { $0.action == "released" && !stillAdded.contains($0.sessionID) }
        if !drop.isEmpty {
            do { try ledger.remove(where: { r in drop.contains(r) }) } catch {
                report.skipped.append(error.localizedDescription)
            }
        }
        return report
    }
}
