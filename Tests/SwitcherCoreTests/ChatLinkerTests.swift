import XCTest
@testable import SwitcherCore

final class ChatLinkerTests: XCTestCase {
    private var home: URL!
    private var paths: Paths!
    private var win: Profile!
    private var lose: Profile!
    private let chatID = "local_aaaa1111"
    private let cli = "cli-1111"
    private let winCwd = "/w/wt-win"
    private let loseCwd = "/w/wt-lose"
    private var openNow: [URL] = []
    private var liveNow: [(pid: pid_t, profileDir: String, cliSessionID: String)] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("chat-linker-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(home: home)
        win = Profile(id: "Default", name: "Default", path: paths.defaultProfile)
        lose = Profile(id: "Two", name: "Two", path: paths.profileDir(id: "Two"))
        for p in [win!, lose!] { try FileManager.default.createDirectory(at: p.path, withIntermediateDirectories: true) }
        openNow = []; liveNow = []
    }

    override func tearDownWithError() throws {
        for d in [recordURL(win), recordURL(lose)] { chmod(d.deletingLastPathComponent().path, 0o700) }
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: fixtures

    private func writeJSON(_ obj: Any, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: url)
    }

    private func recordURL(_ p: Profile) -> URL {
        p.path.appendingPathComponent("claude-code-sessions/acct/org/\(chatID).json")
    }

    private func transcript(_ cwd: String) -> URL { TranscriptLocator.transcript(root: paths.transcriptsRoot, cwd: cwd, cliSessionID: cli) }

    private func record(cwd: String, extra: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = ["sessionId": chatID, "cliSessionId": cli, "cwd": cwd, "worktreePath": cwd, "title": "T",
                                "bridgeSessionIds": ["b1"], "unknownField": 7]
        for (k, v) in extra { r[k] = v }
        return r
    }

    private func lease(_ path: String, name: String, by: Any) -> [String: Any] {
        ["name": name, "path": path, "leasedBy": by, "branch": "x"]
    }

    private func leaseFile(_ entries: [String: Any]) -> [String: Any] { ["schemaVersion": 2, "worktrees": entries, "keep": "me"] }

    private func transcriptText(_ cwd: String, _ text: String) throws {
        let url = transcript(cwd)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Winner and loser each with their own folder, record, lease and history.
    private func diverged(loserLease: Bool = true, winnerWorktree: Bool = true) throws {
        var wr = record(cwd: winCwd, extra: ["isStarred": true, "scheduledTaskId": "s1"])
        if !winnerWorktree { wr.removeValue(forKey: "worktreePath") }
        try writeJSON(wr, recordURL(win))
        try writeJSON(record(cwd: loseCwd, extra: ["isArchived": true]), recordURL(lose))
        try writeJSON(leaseFile(["wt-win": lease(winCwd, name: "wt-win", by: chatID)]), WorktreeLeases.file(win))
        if loserLease { try writeJSON(leaseFile(["wt-lose": lease(loseCwd, name: "wt-lose", by: chatID)]), WorktreeLeases.file(lose)) }
        try transcriptText(winCwd, "{\"a\":1}\n{\"a\":2}\n")
        try transcriptText(loseCwd, "{\"a\":1}\n")
        let side = TranscriptLocator.sidecar(root: paths.transcriptsRoot, cwd: loseCwd, cliSessionID: cli)
        try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        try "x".write(to: side.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    }

    private func chat() throws -> SharedChat {
        let found = SharedChatScanner(transcriptsRoot: paths.transcriptsRoot).scan([win, lose])
        return try XCTUnwrap(found.first { $0.id == chatID })
    }

    private func linker() -> ChatLinker {
        ChatLinker(paths: paths, ledger: LinksLedger(file: paths.switcherHome.appendingPathComponent("links.json")),
                   live: { [unowned self] in self.liveNow }, openFolders: { [unowned self] in self.openNow })
    }

    private func ledger() -> LinksLedger { LinksLedger(file: paths.switcherHome.appendingPathComponent("links.json")) }

    private func obj(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func worktrees(_ p: Profile) throws -> [String: Any] { try XCTUnwrap(try obj(WorktreeLeases.file(p))["worktrees"] as? [String: Any]) }

    private func backupFiles() -> [String] {
        let base = paths.switcherHome.appendingPathComponent("backups/transcripts")
        guard let e = FileManager.default.enumerator(atPath: base.path) else { return [] }
        return (e.allObjects as? [String]) ?? []
    }

    // MARK: link

    func testLinkRepointsLoserRecordAndKeepsArchiveAndStar() throws {
        try diverged()
        let report = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report, LinkReport(linked: ["Two"], skipped: [:]))
        let r = try obj(recordURL(lose))
        XCTAssertEqual(r["cwd"] as? String, winCwd)
        XCTAssertEqual(r["worktreePath"] as? String, winCwd)
        XCTAssertEqual(r["isArchived"] as? Bool, true)
        XCTAssertNil(r["isStarred"])          // loser had none; the winner's star is not taken over
        XCTAssertNil(r["scheduledTaskId"])
        XCTAssertEqual((r["bridgeSessionIds"] as? [Any])?.count, 0)
        XCTAssertEqual(r["unknownField"] as? Int, 7)
        // The winner is untouched.
        XCTAssertEqual(try obj(recordURL(win))["isStarred"] as? Bool, true)
        let mode = (try FileManager.default.attributesOfItem(atPath: recordURL(lose).path)[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testLinkMovesLoserTranscriptToBackupNeverDeletes() throws {
        try diverged()
        _ = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertEqual(try String(contentsOf: transcript(winCwd)), "{\"a\":1}\n{\"a\":2}\n")
        let files = backupFiles()
        let moved = try XCTUnwrap(files.first { $0.hasSuffix("/\(cli).jsonl") })
        XCTAssertTrue(moved.contains("/Two/"))
        XCTAssertEqual(try String(contentsOf: paths.switcherHome.appendingPathComponent("backups/transcripts/" + moved)), "{\"a\":1}\n")
        XCTAssertTrue(files.contains { $0.hasSuffix("/\(cli)/f.txt") })
    }

    func testLinkReleasesLoserOldLeaseAndAddsWinnerLease() throws {
        try diverged()
        _ = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        let w = try worktrees(lose)
        let old = try XCTUnwrap(w["wt-lose"] as? [String: Any])
        XCTAssertTrue(old["leasedBy"] is NSNull)
        XCTAssertEqual(old["leaseCleared"] as? Bool, true)
        let added = try XCTUnwrap(w["wt-win"] as? [String: Any])
        XCTAssertEqual(added["leasedBy"] as? String, chatID)
        XCTAssertEqual(added["adopted"] as? Bool, true)
        XCTAssertEqual(added["path"] as? String, winCwd)
        XCTAssertEqual(try obj(WorktreeLeases.file(lose))["keep"] as? String, "me")
    }

    func testLinkWritesLedger() throws {
        try diverged()
        _ = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        let recs = ledger().records()
        XCTAssertEqual(recs.count, 2)
        let added = try XCTUnwrap(recs.first { $0.action == "added" })
        XCTAssertEqual(added.profileID, "Two"); XCTAssertEqual(added.entryName, "wt-win"); XCTAssertEqual(added.sessionID, chatID)
        XCTAssertNil(added.previous)
        let writtenObj = try XCTUnwrap(JSONSerialization.jsonObject(with: added.written) as? [String: Any])
        XCTAssertEqual(writtenObj["leasedBy"] as? String, chatID)
        let rel = try XCTUnwrap(recs.first { $0.action == "released" })
        XCTAssertEqual(rel.entryName, "wt-lose")
        let prev = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(rel.previous)) as? [String: Any])
        XCTAssertEqual(prev["leasedBy"] as? String, chatID)
        XCTAssertTrue(ledger().isLinked(sessionID: chatID))
        XCTAssertFalse(ledger().isLinked(sessionID: "local_other"))
        let mode = (try FileManager.default.attributesOfItem(atPath: paths.switcherHome.appendingPathComponent("links.json").path)[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testLinkRefusesWhenSessionProcessIsAlive() throws {
        try diverged()
        let c = try chat()
        liveNow = [(pid: 1, profileDir: "/other", cliSessionID: cli)]
        XCTAssertThrowsError(try linker().link(c, winner: "Default", profiles: [win, lose]))
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertTrue(ledger().records().isEmpty)
    }

    func testLinkRefusesWhenLoserIsOpen() throws {
        try diverged()
        let c = try chat()
        openNow = [lose.path]
        let report = try linker().link(c, winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report.linked, [])
        XCTAssertNotNil(report.skipped["Two"])
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
    }

    func testLinkRefusesUnsupportedLeaseFile() throws {
        try diverged()
        try writeJSON(["schemaVersion": 3, "worktrees": [:]], WorktreeLeases.file(lose))
        let report = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report.linked, [])
        XCTAssertNotNil(report.skipped["Two"])
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertTrue(ledger().records().isEmpty)
    }

    func testLinkWithoutWorktreeOnlyRepointsRecord() throws {
        try diverged(winnerWorktree: false)
        try? FileManager.default.removeItem(at: WorktreeLeases.file(lose))
        let report = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report.linked, ["Two"])
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, winCwd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: WorktreeLeases.file(lose).path))   // never created
        XCTAssertTrue(ledger().records().isEmpty)
    }

    func testLinkNeverMovesTheWinnersTranscript() throws {
        // The loser's record already points at the winner's folder but holds no lease: willSplit.
        try diverged()
        try writeJSON(record(cwd: winCwd, extra: ["isArchived": true]), recordURL(lose))
        try writeJSON(leaseFile([:]), WorktreeLeases.file(lose))
        try? FileManager.default.removeItem(at: transcript(loseCwd))
        let c = try chat()
        XCTAssertEqual(c.status["Two"], .willSplit)
        let before = try Data(contentsOf: transcript(winCwd))
        let report = try linker().link(c, winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report.linked, ["Two"])
        XCTAssertEqual(try Data(contentsOf: transcript(winCwd)), before)
        XCTAssertTrue(backupFiles().filter { $0.hasSuffix(".jsonl") }.isEmpty)
        XCTAssertEqual(try worktrees(lose)["wt-win"].flatMap { ($0 as? [String: Any])?["leasedBy"] as? String }, chatID)
    }

    func testLinkAlreadyLinkedWritesNothing() throws {
        try diverged()
        _ = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        let before = ledger().records().count
        let leaseBefore = try Data(contentsOf: WorktreeLeases.file(lose))
        let again = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        XCTAssertEqual(again.linked, ["Two"])
        XCTAssertEqual(ledger().records().count, before)
        XCTAssertEqual(try Data(contentsOf: WorktreeLeases.file(lose)), leaseBefore)
    }

    // MARK: bindOnTransfer

    private func session(worktree: String?) -> CodeSession {
        CodeSession(file: recordURL(win), sessionID: String(chatID.dropFirst("local_".count)), cliSessionID: cli, priorCLISessionIDs: [],
                    title: "T", folder: "f", updated: Date(), hasTranscript: true, worktreePath: worktree)
    }

    func testBindOnTransferAddsLeaseOrExplainsWhyNot() throws {
        try writeJSON(leaseFile(["wt-win": lease(winCwd, name: "wt-win", by: chatID)]), WorktreeLeases.file(win))
        XCTAssertNil(linker().bindOnTransfer(session: session(worktree: nil), from: win, to: lose))
        // No lease file in the target: the exact explanation, and nothing is created.
        XCTAssertEqual(linker().bindOnTransfer(session: session(worktree: winCwd), from: win, to: lose),
                       L("Claude doesn't keep a worktree list in this account yet; open one chat that uses a worktree in it once.",
                         "Claude bu hesapta henüz worktree kaydı tutmuyor; bu hesapta bir kez worktree'li bir sohbet açın."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: WorktreeLeases.file(lose).path))
        try writeJSON(leaseFile([:]), WorktreeLeases.file(lose))
        XCTAssertNil(linker().bindOnTransfer(session: session(worktree: winCwd), from: win, to: lose))
        let added = try XCTUnwrap(try worktrees(lose)["wt-win"] as? [String: Any])
        XCTAssertEqual(added["leasedBy"] as? String, chatID)
        XCTAssertEqual(ledger().records().map(\.action), ["added"])
        // Doing it again changes nothing.
        XCTAssertNil(linker().bindOnTransfer(session: session(worktree: winCwd), from: win, to: lose))
        XCTAssertEqual(ledger().records().count, 1)
    }

    func testBindOnTransferRefusesWhenTargetCopyHasOtherFolder() throws {
        try diverged()
        let leaseBefore = try Data(contentsOf: WorktreeLeases.file(lose))
        let why = linker().bindOnTransfer(session: session(worktree: winCwd), from: win, to: lose)
        XCTAssertEqual(why, L("The copy in this account has its own history; use Sync in Shared chats.",
                              "Bu hesaptaki kopyanın kendi geçmişi var; Ortak sohbetler'deki Eşitle'yi kullanın."))
        XCTAssertEqual(try Data(contentsOf: WorktreeLeases.file(lose)), leaseBefore)
        XCTAssertTrue(ledger().records().isEmpty)
    }

    // MARK: unlink

    func testUnlinkRemovesOnlyUnchangedEntries() throws {
        try diverged()
        _ = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        // Claude changed the added entry meanwhile: it must stay.
        var w = try worktrees(lose)
        var e = try XCTUnwrap(w["wt-win"] as? [String: Any]); e["branch"] = "changed"; w["wt-win"] = e
        try writeJSON(leaseFile(w), WorktreeLeases.file(lose))
        var report = linker().unlink(sessionID: chatID, profiles: [win, lose])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertNotNil(try worktrees(lose)["wt-win"])
        XCTAssertEqual(ledger().records().count, 2)   // nothing dropped
        // Restore the entry as written: now it goes.
        e["branch"] = "x"; w["wt-win"] = e
        try writeJSON(leaseFile(w), WorktreeLeases.file(lose))
        openNow = [lose.path]
        report = linker().unlink(sessionID: chatID, profiles: [win, lose])
        XCTAssertEqual(report.removed, 0)             // open profile: skipped
        XCTAssertNotNil(try worktrees(lose)["wt-win"])
        openNow = []
        report = linker().unlink(sessionID: nil, profiles: [win, lose])
        XCTAssertEqual(report, UnlinkReport(removed: 1, skipped: []))
        XCTAssertNil(try worktrees(lose)["wt-win"])
        XCTAssertNotNil(try worktrees(lose)["wt-lose"])   // released lease is not restored
        XCTAssertTrue(ledger().records().isEmpty)
        XCTAssertFalse(ledger().isLinked(sessionID: chatID))
    }

    // MARK: fix round 1

    func testLedgerFailureWritesNothing() throws {
        try diverged()
        let c = try chat()
        try FileManager.default.createDirectory(at: paths.switcherHome, withIntermediateDirectories: true)
        try "not json".write(to: paths.switcherHome.appendingPathComponent("links.json"), atomically: true, encoding: .utf8)
        let leaseBefore = try Data(contentsOf: WorktreeLeases.file(lose)), recBefore = try Data(contentsOf: recordURL(lose))
        let report = try linker().link(c, winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report.linked, [])
        XCTAssertNotNil(report.skipped["Two"])
        XCTAssertEqual(try Data(contentsOf: WorktreeLeases.file(lose)), leaseBefore)
        XCTAssertEqual(try Data(contentsOf: recordURL(lose)), recBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertEqual(try String(contentsOf: paths.switcherHome.appendingPathComponent("links.json")), "not json")
    }

    func testRecordFailureRollsBackLease() throws {
        try diverged()
        let c = try chat()
        let leaseBefore = try Data(contentsOf: WorktreeLeases.file(lose))
        chmod(recordURL(lose).deletingLastPathComponent().path, 0o500)
        let report = try linker().link(c, winner: "Default", profiles: [win, lose])
        chmod(recordURL(lose).deletingLastPathComponent().path, 0o700)
        XCTAssertEqual(report.linked, [])
        XCTAssertNotNil(report.skipped["Two"])
        XCTAssertTrue(NSDictionary(dictionary: try obj(WorktreeLeases.file(lose))).isEqual(to: try XCTUnwrap(JSONSerialization.jsonObject(with: leaseBefore) as? [String: Any])))
        XCTAssertTrue(ledger().records().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
    }

    func testCaseDifferentWinnerPathIsNotMoved() throws {
        let wcwd = home.path + "/proj/wt-win", lcwd = home.path + "/PROJ/wt-win"
        try FileManager.default.createDirectory(atPath: wcwd, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: lcwd) else { throw XCTSkip("case-sensitive volume") }
        try writeJSON(record(cwd: wcwd), recordURL(win))
        try writeJSON(record(cwd: lcwd), recordURL(lose))
        try writeJSON(leaseFile(["wt-win": lease(wcwd, name: "wt-win", by: chatID)]), WorktreeLeases.file(win))
        try writeJSON(leaseFile([:]), WorktreeLeases.file(lose))
        let url = transcript(wcwd)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"a\":1}\n".write(to: url, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: url)
        let report = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report.linked, ["Two"])
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(backupFiles().filter { $0.hasSuffix(".jsonl") }.isEmpty)
    }

    func testLinkRefusesLeaseHeldByAnotherChat() throws {
        try diverged()
        let c = try chat()
        try writeJSON(leaseFile(["wt-lose": lease(loseCwd, name: "wt-lose", by: chatID),
                                 "wt-win": lease(winCwd, name: "wt-win", by: "local_zzzz")]), WorktreeLeases.file(lose))
        let leaseBefore = try Data(contentsOf: WorktreeLeases.file(lose))
        let report = try linker().link(c, winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report.linked, [])
        XCTAssertNotNil(report.skipped["Two"])
        XCTAssertEqual(try Data(contentsOf: WorktreeLeases.file(lose)), leaseBefore)
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertTrue(ledger().records().isEmpty)
    }

    func testLinkSkipsCliSessionMismatch() throws {
        try diverged()
        let c = try chat()
        try writeJSON(record(cwd: loseCwd, extra: ["cliSessionId": "other-cli"]), recordURL(lose))
        let report = try linker().link(c, winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report.linked, [])
        XCTAssertNotNil(report.skipped["Two"])
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
    }

    // MARK: final review fixes

    private func uuidLines(_ ids: [String]) -> String { ids.map { "{\"uuid\":\"\($0)\"}\n" }.joined() }

    private let staleMessage = L("This chat changed since it was checked; refresh and try again.", "Bu sohbet kontrol edildikten sonra değişti; yenileyip tekrar deneyin.")

    func testLinkRefusesWhenLoserGrewAfterScan() throws {
        try diverged()
        let c = try chat()      // the loser looked behind
        try transcriptText(loseCwd, "{\"a\":1}\n{\"uuid\":\"new\"}\n")   // ...then it was continued
        let report = try linker().link(c, winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report, LinkReport(linked: [], skipped: ["Two": staleMessage]))
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertTrue(ledger().records().isEmpty)
    }

    func testLinkAcceptsPickedForkOnlyWhenUnchanged() throws {
        try diverged()
        try transcriptText(winCwd, uuidLines(["c", "w1"]) + "{\"pad\":\"xxxxxxxxxxxxxxxx\"}\n")   // larger, so it is the reference
        try transcriptText(loseCwd, uuidLines(["c", "l1"]))
        let c = try chat()
        XCTAssertEqual(c.status["Two"], .forked(messages: 1))
        // Not picked as a fork: refused.
        XCTAssertEqual(try linker().link(c, winner: "Default", profiles: [win, lose]).skipped["Two"], staleMessage)
        // Picked, but the loser has grown since: refused.
        try transcriptText(loseCwd, uuidLines(["c", "l1", "l2"]))
        XCTAssertEqual(try linker().link(c, winner: "Default", profiles: [win, lose], expectedForks: ["Two": 1]).skipped["Two"], staleMessage)
        XCTAssertTrue(ledger().records().isEmpty)
        // Picked and unchanged: linked.
        try transcriptText(loseCwd, uuidLines(["c", "l1"]))
        let report = try linker().link(c, winner: "Default", profiles: [win, lose], expectedForks: ["Two": 1])
        XCTAssertEqual(report.linked, ["Two"])
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, winCwd)
    }

    func testPickedForkWhereLatestIsLoserRefusesGrowthAfterScan() throws {
        try diverged()
        // Default is the furthest copy (reference); Two forked off it. The user keeps Two, so Default loses.
        try transcriptText(winCwd, uuidLines(["c", "w1", "w2"]) + "{\"pad\":\"xxxxxxxxxxxxxxxx\"}\n")
        try transcriptText(loseCwd, uuidLines(["c", "l1"]))
        let c = try chat()
        XCTAssertEqual(c.status["Default"], .latest)
        XCTAssertEqual(c.status["Two"], .forked(messages: 1))
        let expected = LinkPolicy.expectedForks(c, winner: "Two")
        XCTAssertEqual(expected, ["Default": 2], "the up-to-date copy's own messages, as counted when the chat was scanned")
        // The up-to-date copy is continued between the scan and the click.
        try transcriptText(winCwd, uuidLines(["c", "w1", "w2", "w3"]) + "{\"pad\":\"xxxxxxxxxxxxxxxx\"}\n")
        let before = try Data(contentsOf: recordURL(win))
        let report = try linker().link(c, winner: "Two", profiles: [win, lose], expectedForks: expected)
        XCTAssertEqual(report, LinkReport(linked: [], skipped: ["Default": staleMessage]))
        XCTAssertEqual(try Data(contentsOf: recordURL(win)), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(winCwd).path))
        XCTAssertTrue(backupFiles().isEmpty)
        XCTAssertTrue(ledger().records().isEmpty)
    }

    func testPickedForkWhereLatestIsLoserIsLinkedWhenUnchanged() throws {
        try diverged()
        try transcriptText(winCwd, uuidLines(["c", "w1", "w2"]) + "{\"pad\":\"xxxxxxxxxxxxxxxx\"}\n")
        try transcriptText(loseCwd, uuidLines(["c", "l1"]))
        let c = try chat()
        let report = try linker().link(c, winner: "Two", profiles: [win, lose], expectedForks: LinkPolicy.expectedForks(c, winner: "Two"))
        XCTAssertEqual(report.linked, ["Default"])
    }

    func testPickedForkWithoutScanTimeCountIsRefused() throws {
        try diverged()
        try transcriptText(winCwd, uuidLines(["c", "w1", "w2"]) + "{\"pad\":\"xxxxxxxxxxxxxxxx\"}\n")
        try transcriptText(loseCwd, uuidLines(["c", "l1"]))
        let c = try chat()
        // A chat value without the scan-time numbers (e.g. built by hand): nothing to check against, so refused.
        let bare = SharedChat(id: c.id, cliSessionID: c.cliSessionID, title: c.title, folder: c.folder, copies: c.copies, status: c.status, isLinked: c.isLinked)
        let expected = LinkPolicy.expectedForks(bare, winner: "Two")
        XCTAssertNil(expected["Default"])
        XCTAssertEqual(try linker().link(bare, winner: "Two", profiles: [win, lose], expectedForks: expected).skipped["Default"], staleMessage)
    }

    /// Default (winner) + Two + Four; Four sorts before Two; both losers use the loser's folder and so one history file.
    private func sharedLosers() throws -> (chat: SharedChat, four: Profile) {
        try diverged()
        let four = Profile(id: "Four", name: "Four", path: paths.profileDir(id: "Four"))
        try FileManager.default.createDirectory(at: four.path, withIntermediateDirectories: true)
        try writeJSON(record(cwd: loseCwd), recordURL(four))
        try writeJSON(leaseFile(["wt-lose": lease(loseCwd, name: "wt-lose", by: chatID)]), WorktreeLeases.file(four))
        addTeardownBlock { chmod(self.recordURL(four).deletingLastPathComponent().path, 0o700) }
        let c = try XCTUnwrap(SharedChatScanner(transcriptsRoot: paths.transcriptsRoot).scan([win, lose, four]).first { $0.id == chatID })
        return (c, four)
    }

    func testSharedFileProtectionIndependentOfOrder() throws {
        let (c, four) = try sharedLosers()
        // Open-check calls: 1-2 planning (Four, Two), 3-4 pass 1 (Four, Two), 5 pass 2 (Four only).
        // Two reads as open from the 4th call on, i.e. at its pass 1 re-check.
        var calls = 0
        let late = ChatLinker(paths: paths, ledger: ledger(), live: { [] }, openFolders: {
            calls += 1
            return calls > 3 ? [self.lose.path] : []
        })
        let report = try late.link(c, winner: "Default", profiles: [win, lose, four])
        XCTAssertEqual(calls, 5, "planning, pass 1 and pass 2 each check the accounts they handle")
        XCTAssertNotNil(report.skipped["Two"])
        XCTAssertEqual(report.linked, ["Four"])
        XCTAssertNotNil(report.warnings["Four"], "its old history file is kept for Two")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertTrue(backupFiles().filter { $0.hasSuffix(".jsonl") }.isEmpty)
    }

    func testSharedFileKeptWhenOpenAppearsBetweenPassOneAndTwo() throws {
        let (c, four) = try sharedLosers()
        var calls = 0
        let late = ChatLinker(paths: paths, ledger: ledger(), live: { [] }, openFolders: {
            calls += 1
            return calls > 5 ? [self.lose.path] : []      // Two's pass 2 check is the 6th call
        })
        let report = try late.link(c, winner: "Default", profiles: [win, lose, four])
        XCTAssertEqual(calls, 6)
        XCTAssertEqual(report.skipped["Two"], L("Claude is open in this account. Quit it and try again.", "Bu hesapta Claude açık. Kapatıp tekrar deneyin."))
        XCTAssertEqual(report.linked, ["Four"])
        XCTAssertNotNil(report.warnings["Four"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
    }

    func testSharedFileKeptWhenOtherLoserFailsInWritePhase() throws {
        let (c, four) = try sharedLosers()
        // Two's record can't be rewritten (its folder is read-only), after Four was already relinked.
        let dir = recordURL(lose).deletingLastPathComponent()
        chmod(dir.path, 0o500)
        defer { chmod(dir.path, 0o700) }
        let report = try linker().link(c, winner: "Default", profiles: [win, lose, four])
        XCTAssertEqual(report.linked, ["Four"])
        XCTAssertNotNil(report.skipped["Two"])
        XCTAssertNotNil(report.warnings["Four"], "its old history file is kept for Two")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))
        XCTAssertTrue(backupFiles().filter { $0.hasSuffix(".jsonl") }.isEmpty)
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
    }

    func testLinkRefusesWhenWinnerRecordPointsAtAnotherHistory() throws {
        try diverged()
        let c = try chat()
        try writeJSON(record(cwd: winCwd, extra: ["cliSessionId": "other-cli"]), recordURL(win))
        XCTAssertThrowsError(try linker().link(c, winner: "Default", profiles: [win, lose]))
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, loseCwd)
    }

    func testTranscriptSharedWithSkippedCopyIsNotMoved() throws {
        try diverged()
        let three = Profile(id: "Three", name: "Three", path: paths.profileDir(id: "Three"))
        try FileManager.default.createDirectory(at: three.path, withIntermediateDirectories: true)
        // The third account's copy uses the loser's folder, and so the loser's history file; it is open.
        try writeJSON(record(cwd: loseCwd), recordURL(three))
        try writeJSON(leaseFile(["wt-lose": lease(loseCwd, name: "wt-lose", by: chatID)]), WorktreeLeases.file(three))
        defer { chmod(recordURL(three).deletingLastPathComponent().path, 0o700) }
        let c = try XCTUnwrap(SharedChatScanner(transcriptsRoot: paths.transcriptsRoot).scan([win, lose, three]).first { $0.id == chatID })
        openNow = [three.path]
        let report = try linker().link(c, winner: "Default", profiles: [win, lose, three])
        XCTAssertEqual(report.linked, ["Two"])
        XCTAssertNotNil(report.skipped["Three"])
        XCTAssertNotNil(report.warnings["Two"])
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, winCwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript(loseCwd).path))   // still there for the third copy
        XCTAssertTrue(backupFiles().filter { $0.hasSuffix(".jsonl") }.isEmpty)
    }

    func testLinkBacksUpLoserWorktreeList() throws {
        try diverged()
        let before = try Data(contentsOf: WorktreeLeases.file(lose))
        _ = try linker().link(try chat(), winner: "Default", profiles: [win, lose])
        let rel = try XCTUnwrap(backupFiles().first { $0.hasSuffix("/Two/git-worktrees.json") })
        XCTAssertEqual(try Data(contentsOf: paths.switcherHome.appendingPathComponent("backups/transcripts/" + rel)), before)
    }

    func testMoveFailureAfterRecordRewriteIsLinkedWithWarning() throws {
        try diverged()
        let c = try chat()
        let dir = transcript(loseCwd).deletingLastPathComponent()
        chmod(dir.path, 0o500)      // the history file can't be moved out
        defer { chmod(dir.path, 0o700) }
        let report = try linker().link(c, winner: "Default", profiles: [win, lose])
        XCTAssertEqual(report.linked, ["Two"])
        XCTAssertNil(report.skipped["Two"])
        XCTAssertNotNil(report.warnings["Two"])
        XCTAssertEqual(try obj(recordURL(lose))["cwd"] as? String, winCwd)
    }

    func testTwoLedgersAppendingConcurrentlyKeepEveryRecord() throws {
        let file = paths.switcherHome.appendingPathComponent("links.json")
        let a = LinksLedger(file: file), b = LinksLedger(file: file)
        let rec = { (i: Int) in LinkRecord(profileID: "P\(i)", entryName: "e\(i)", action: "added", previous: nil, written: Data("{}".utf8), at: Date(), sessionID: "s") }
        DispatchQueue.concurrentPerform(iterations: 120) { i in
            try? (i % 2 == 0 ? a : b).append([rec(i)])
        }
        XCTAssertEqual(a.records().count, 120)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path + ".lock")[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }
}
