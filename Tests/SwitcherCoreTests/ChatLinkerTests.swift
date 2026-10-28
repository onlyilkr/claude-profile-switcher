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

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

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
}
