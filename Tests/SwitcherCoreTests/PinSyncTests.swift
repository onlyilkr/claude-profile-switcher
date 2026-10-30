import XCTest
@testable import SwitcherCore

final class PinSyncTests: XCTestCase {
    var home: URL!
    var transfer: ChatTransfer!
    var backupsDir: URL { home.appendingPathComponent("backups/pinstore") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pinsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        transfer = ChatTransfer(transcriptsRoot: home.appendingPathComponent("transcripts"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    /// A profile with both Claude databases (`pins` are the starred chats in sidebar order), the config mirror and one
    /// record per chat. `hasPinRecord: false` leaves the IndexedDB without any pin record.
    func profile(_ id: String, chats: [String], pins: [String], deleted: [String] = [], starred: Set<String>? = nil,
                 org: String = "org", hasPinRecord: Bool = true, lsVersion: String? = "1") throws -> Profile {
        let cfg = try JSONSerialization.data(withJSONObject: ["mcpServers": ["x": 1],
                                                              "preferences": ["epitaxyPrefs": ["starred-local-code-sessions": pins, "other": 5]]])
        let p = try ClaudeStoreFixture.makeProfile(in: home, id: id, name: id, starredIds: hasPinRecord ? pins : nil,
                                                   pinnedOrder: pins.map { "code:" + $0 }, listMirror: pins, lsVersion: lsVersion,
                                                   config: String(decoding: cfg, as: UTF8.self))
        let dir = ChatTransfer.sessionRoot(p).appendingPathComponent("acct").appendingPathComponent(org)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stars = starred ?? Set(pins)
        for c in chats {
            var obj: [String: Any] = ["sessionId": c, "title": c, "cliSessionId": "cli-\(c)"]
            if stars.contains(c) { obj["isStarred"] = true }
            try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("\(c).json"))
        }
        for d in deleted { try Data().write(to: dir.appendingPathComponent("deleted_\(d)")) }
        return p
    }

    func record(_ p: Profile, _ id: String, org: String = "org") throws -> [String: Any] {
        let f = ChatTransfer.sessionRoot(p).appendingPathComponent("acct/\(org)/\(id).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
    }

    func storePins(_ p: Profile) throws -> [String]? { try ClaudePinStore.read(p, tolerateTornTail: false)?.sidebar }

    func backups(_ dir: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains("switcher-backup") }
    }

    func apply(_ plan: PinSyncPlan, to t: Profile, openFolders: [URL] = []) throws {
        try PinSync.apply(plan, to: t, transfer: transfer, openFolders: openFolders, backups: backupsDir, logError: { _ in })
    }

    func testLastUsedOrderWinsForSharedPins() throws {
        let s = try profile("S", chats: ["local_a", "local_b", "local_c"], pins: ["local_c", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_b", "local_c", "local_x"], pins: ["local_a", "local_x", "local_c"])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        XCTAssertEqual(plan.source, "S")
        XCTAssertEqual(plan.newPins, ["local_c", "local_a", "local_x"], "the source's order first, then the target-only pin")
    }

    func testSharedChatUnpinnedInSourceIsUnpinned() throws {
        let s = try profile("S", chats: ["local_s"], pins: [])
        let t = try profile("T", chats: ["local_s"], pins: ["local_s"])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        XCTAssertFalse(plan.newPins.contains("local_s"))
        XCTAssertEqual(plan.unstar, ["local_s"])
        try apply(plan, to: t)
        XCTAssertEqual(try storePins(t), [])
        XCTAssertEqual(try record(t, "local_s")["isStarred"] as? Bool, false)
    }

    func testSourceWithoutPinRecordSkips() throws {
        let noRecord = try profile("S", chats: ["local_a"], pins: [], hasPinRecord: false)
        let t = try profile("T", chats: ["local_a"], pins: ["local_a"])
        var logged: [String] = []
        guard case .skipped = try PinSync.plan(target: t, source: noRecord, transfer: transfer, logError: { logged.append($0) }) else { return XCTFail("expected skipped") }
        XCTAssertTrue(logged.isEmpty, "a source simply without a record skips silently")
        XCTAssertEqual(try storePins(t), ["local_a"])
    }

    func testUnreadableSourceSkips() throws {
        let s = try profile("S", chats: ["local_a"], pins: [])
        let t = try profile("T", chats: ["local_a"], pins: ["local_a"])
        try FileManager.default.removeItem(at: ClaudeStoreFixture.idbFolder(s))
        var logged: [String] = []
        guard case .skipped = try PinSync.plan(target: t, source: s, transfer: transfer, logError: { logged.append($0) }) else { return XCTFail("an unreadable source must not unpin the target") }
        XCTAssertEqual(logged, ["Pin sync for 'T' skipped: source pins unreadable"])
        XCTAssertEqual(try storePins(t), ["local_a"])
    }

    func testTargetWithoutPinRecordIsRefused() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [], hasPinRecord: false)
        XCTAssertThrowsError(try PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change) {
            XCTAssertEqual(($0 as? SwitcherError)?.logReason, "no pin record yet")
        }
    }

    func testStaleTargetPinsAreKept() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: ["local_gone"])   // pinned, but no record of it
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        XCTAssertEqual(plan.newPins, ["local_a", "local_gone"])
    }

    func testOnlyChatsInBothProfilesAreTouched() throws {
        let s = try profile("S", chats: ["local_a", "local_s"], pins: ["local_s", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_t"], pins: ["local_t"])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        XCTAssertEqual(plan.newPins, ["local_a", "local_t"], "local_s is not in the target and is not brought along")
        XCTAssertEqual(plan.star, ["local_a"])
        XCTAssertEqual(plan.unstar, [])
        try apply(plan, to: t)
        XCTAssertEqual(try record(t, "local_t")["isStarred"] as? Bool, true)
    }

    func testDeletedChatsAreIgnored() throws {
        let s = try profile("S", chats: ["local_a", "local_d"], pins: ["local_d", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_d"], pins: [], deleted: ["d"])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        XCTAssertEqual(plan.newPins, ["local_a"])
        XCTAssertEqual(plan.star, ["local_a"])
    }

    func testApplyWritesClaudeStoreAndMirrors() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_b"])
        // the same chat also sits in a second organisation folder
        let second = ChatTransfer.sessionRoot(t).appendingPathComponent("acct/org2")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_a", "extra": 1]).write(to: second.appendingPathComponent("local_a.json"))
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        try apply(plan, to: t)
        XCTAssertEqual(try ClaudePinStore.read(t, tolerateTornTail: false)?.sidebar, plan.newPins)
        XCTAssertEqual(try storePins(t), ["local_a"])
        XCTAssertEqual(transfer.pins(of: t), plan.newPins, "the config mirror follows")
        XCTAssertEqual(try record(t, "local_a")["isStarred"] as? Bool, true)
        XCTAssertEqual(try record(t, "local_a", org: "org2")["isStarred"] as? Bool, true)
        XCTAssertEqual(try record(t, "local_a", org: "org2")["extra"] as? Int, 1, "other fields kept")
        XCTAssertEqual(try record(t, "local_b")["isStarred"] as? Bool, false)
        XCTAssertEqual(try record(t, "local_b")["title"] as? String, "local_b")
        XCTAssertFalse(backups(ChatTransfer.sessionRoot(t)).isEmpty, "records are backed up before being written")
        XCTAssertFalse(backups(t.path).filter { $0.hasPrefix("claude_desktop_config") }.isEmpty)
        XCTAssertFalse(((try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []).isEmpty, "the store is backed up")
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: ChatTransfer.configFile(t))) as! [String: Any]
        XCTAssertNotNil(cfg["mcpServers"], "other config keys kept")
        XCTAssertNil(try PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change, "and nothing is left to do")
    }

    func testNothingToChangeIsNoChange() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_a", "local_b"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_a", "local_b"])
        guard case .noChange = try PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }) else { return XCTFail("expected noChange") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupsDir.path))
        XCTAssertEqual(backups(t.path), [])
    }

    func testSourceIsMostRecentlyUsedOtherProfileAndNewerThanTarget() throws {
        let t = try profile("T", chats: ["local_a"], pins: [])
        let a = try profile("A", chats: ["local_a"], pins: [])
        let b = try profile("B", chats: ["local_a"], pins: [])
        let c = try profile("C", chats: ["local_z"], pins: [])
        let now = Date()
        let dates = ["T": now.addingTimeInterval(-100), "A": now.addingTimeInterval(-50), "B": now.addingTimeInterval(-10), "C": now]
        let pick = { (among: [Profile], d: [String: Date]) in
            PinSync.source(for: t, among: among, lastUsed: { d[$0.id] }, transfer: self.transfer)?.id
        }
        XCTAssertEqual(pick([t, a, b, c], dates), "B", "newest among those sharing chats; C shares none; the target is skipped")
        var older = dates; older["A"] = now.addingTimeInterval(-200); older["B"] = now.addingTimeInterval(-300)
        XCTAssertNil(pick([t, a, b], older), "nothing newer than the target")
        XCTAssertNil(pick([t, a], ["T": now, "A": now]), "equal is not newer")
    }

    func testOpenTargetIsRefused() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        XCTAssertThrowsError(try apply(plan, to: t, openFolders: [t.path]))
        XCTAssertEqual(try storePins(t), [])
        XCTAssertEqual(transfer.pins(of: t), [])
        XCTAssertNil(try record(t, "local_a")["isStarred"])
    }

    /// The tests below need a volume that ignores case (the default APFS one).
    private func skipUnlessCaseInsensitive() throws {
        try Data().write(to: home.appendingPathComponent("probe"))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: home.appendingPathComponent("PROBE").path), "case-sensitive volume")
    }

    private func upperCased(_ url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.uppercased()) }

    func testWritePinsRefusesAConfigLinkedIntoAnOpenProfileSpelledInOtherCase() throws {
        // End-to-end guard: Foundation already normalises case for an existing target, so this also passes on the old string check.
        try skipUnlessCaseInsensitive()
        let a = try profile("Alpha", chats: ["local_1"], pins: [])
        let b = try profile("Beta", chats: ["local_1"], pins: [])
        let linked = ChatTransfer.configFile(b)
        try FileManager.default.removeItem(at: linked)
        let spelled = upperCased(a.path).appendingPathComponent(ChatTransfer.configFile(a).lastPathComponent)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: spelled)
        let before = try Data(contentsOf: ChatTransfer.configFile(a))
        XCTAssertThrowsError(try transfer.writePins(["local_1"], to: b, openFolders: [upperCased(a.path)]))
        XCTAssertEqual(try Data(contentsOf: ChatTransfer.configFile(a)), before, "the open profile's config is unchanged")
    }

    func testWritePinsRefusesAnOpenProfileSpelledInOtherCaseWhenItHasNoConfigYet() throws {
        try skipUnlessCaseInsensitive()
        let a = try profile("Alpha", chats: ["local_1"], pins: [])
        try FileManager.default.removeItem(at: ChatTransfer.configFile(a))
        // With no file to resolve, the spelling of the target path stays as written.
        let spelled = Profile(id: "Alpha", name: "Alpha", path: upperCased(a.path))
        XCTAssertThrowsError(try transfer.writePins(["local_1"], to: spelled, openFolders: [a.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChatTransfer.configFile(a).path), "nothing was written into the open profile")
    }

    func testPinSyncApplyRefusesAnOpenTargetSpelledInOtherCase() throws {
        try skipUnlessCaseInsensitive()
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("Target", chats: ["local_a"], pins: [])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        XCTAssertThrowsError(try apply(plan, to: t, openFolders: [upperCased(t.path)]))
        XCTAssertEqual(try storePins(t), [])
    }

    func testStalePlanIsRefused() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: [])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        _ = try ClaudePinStore.write(["local_b"], to: t, backups: backupsDir)
        XCTAssertThrowsError(try apply(plan, to: t)) {
            XCTAssertEqual(($0 as? SwitcherError)?.logReason, "pins changed since planning")
        }
        XCTAssertEqual(try storePins(t), ["local_b"])
        XCTAssertNil(try record(t, "local_a")["isStarred"])
    }

    func testRecordMirrorFailureIsLoggedNotFatalAndHealedNextTime() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_a", "local_b"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: [])
        let locked = ChatTransfer.sessionRoot(t).appendingPathComponent("acct/org2")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_b"]).write(to: locked.appendingPathComponent("local_b.json"))
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o700) }
        var logged: [String] = []
        try PinSync.apply(plan, to: t, transfer: transfer, openFolders: [], backups: backupsDir, logError: { logged.append($0) })
        XCTAssertEqual(logged, ["Pin sync for 'T': 1 record mirror(s) not updated"])
        XCTAssertEqual(try storePins(t), ["local_a", "local_b"], "the store is written")
        XCTAssertEqual(try record(t, "local_a")["isStarred"] as? Bool, true, "the other records were still written")
        chmod(locked.path, 0o700)
        let again = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change, "the right store still has a mirror to heal")
        XCTAssertEqual(again.newPins, ["local_a", "local_b"])
        XCTAssertEqual(again.star, ["local_b"])
        try apply(again, to: t)
        XCTAssertEqual(try record(t, "local_b", org: "org2")["isStarred"] as? Bool, true)
        XCTAssertNil(try PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
    }

    func testUnreadableConfigMirrorDoesNotFailTheSync() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [])
        let broken = Data(#"{"mcpServers": {"#.utf8)
        try broken.write(to: ChatTransfer.configFile(t))
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        var logged: [String] = []
        try PinSync.apply(plan, to: t, transfer: transfer, openFolders: [], backups: backupsDir, logError: { logged.append($0) })
        XCTAssertEqual(try storePins(t), ["local_a"])
        XCTAssertEqual(logged, ["Pin sync for 'T': config mirror not updated"])
        XCTAssertEqual(try Data(contentsOf: ChatTransfer.configFile(t)), broken, "the config is left as it was")
    }

    func testMirrorsAreRepairedWhenTheStoreIsAlreadyRight() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: ["local_a"], starred: [])   // store right, record not starred
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        XCTAssertEqual(plan.newPins, plan.seen.sidebar)
        let before = try ClaudeStoreFixture.snapshot(t.path.appendingPathComponent("IndexedDB"))
        try apply(plan, to: t)
        XCTAssertEqual(try record(t, "local_a")["isStarred"] as? Bool, true)
        XCTAssertEqual(try ClaudeStoreFixture.snapshot(t.path.appendingPathComponent("IndexedDB")), before, "the store is not rewritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupsDir.path), "and not backed up")
    }

    func testUnstarRecordWithoutKey() throws {
        let s = try profile("S", chats: ["local_a"], pins: [])
        let t = try profile("T", chats: ["local_a"], pins: [], starred: [])
        XCTAssertNil(try PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change, "no pin and no star: nothing to do")
        let u = try profile("U", chats: ["local_a"], pins: ["local_a"], starred: [])
        let plan = try XCTUnwrap(PinSync.plan(target: u, source: s, transfer: transfer, logError: { _ in }).change)
        try apply(plan, to: u)
        XCTAssertNil(try record(u, "local_a")["isStarred"], "no write needed for a record without the key")
        XCTAssertEqual(try storePins(u), [])
    }

    // MARK: Launch path

    final class Lines { var info: [String] = []; var errors: [String] = []; var problems: [String?] = []; var problemIDs: [String] = []; var stop: SwitcherError? }

    func runLaunchSync(_ t: Profile, _ s: Profile, enabled: Bool = true, open: [URL] = [], lines: Lines = Lines()) -> Lines {
        let now = Date()
        lines.stop = Switcher.syncPinsBeforeLaunch(target: t, among: [s, t], openFolders: open, enabled: enabled, transfer: transfer,
                                      backups: backupsDir, lastUsed: { $0.id == "S" ? now : now.addingTimeInterval(-3600) },
                                      problem: { lines.problemIDs.append($0); lines.problems.append($1) },
                                      log: { lines.info.append($0) }, logError: { lines.errors.append($0) })
        return lines
    }

    func testLaunchSyncsPinsBeforeStartingWhenEnabled() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_b", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_a"])
        let lines = runLaunchSync(t, s)
        XCTAssertEqual(try storePins(t), ["local_b", "local_a"])
        XCTAssertEqual(lines.info, ["Pins synced from 'S' to 'T' (1 pinned, 0 unpinned)"])
        XCTAssertTrue(lines.errors.isEmpty)
        XCTAssertEqual(lines.problems.count, 1)
        XCTAssertNil(lines.problems[0], "a successful sync clears the problem")
    }

    func testLaunchSkipsPinSyncWhenDisabled() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_b", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_a"])
        let lines = runLaunchSync(t, s, enabled: false)
        XCTAssertEqual(try storePins(t), ["local_a"])
        XCTAssertTrue(lines.info.isEmpty && lines.errors.isEmpty && lines.problems.isEmpty)
    }

    func testLaunchSkipsPinSyncForRunningTarget() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_b", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_a"])
        let lines = runLaunchSync(t, s, open: [t.path])
        XCTAssertEqual(try storePins(t), ["local_a"])
        XCTAssertTrue(lines.info.isEmpty && lines.errors.isEmpty)
    }

    func testNothingToChangeClearsTheProblem() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: ["local_a"])
        let lines = runLaunchSync(t, s)
        XCTAssertTrue(lines.info.isEmpty && lines.errors.isEmpty)
        XCTAssertEqual(lines.problems.count, 1)
        XCTAssertNil(lines.problems[0])
    }

    func testSourceWithoutPinRecordSetsNoProblem() throws {
        let s = try profile("S", chats: ["local_a"], pins: [], hasPinRecord: false)
        let t = try profile("T", chats: ["local_a"], pins: ["local_a"])
        let lines = runLaunchSync(t, s)
        XCTAssertTrue(lines.info.isEmpty && lines.errors.isEmpty)
        XCTAssertEqual(try storePins(t), ["local_a"])
        XCTAssertFalse(lines.problems.contains { $0 != nil })
    }

    func testUnreadableSourceKeepsTheProblemAndLogsAFixedReason() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [])
        try FileManager.default.removeItem(at: ClaudeStoreFixture.idbFolder(s))
        let lines = runLaunchSync(t, s)
        XCTAssertTrue(lines.problems.isEmpty, "the target was never read, so the note is neither set nor cleared")
        XCTAssertEqual(lines.errors, ["Pin sync for 'T' skipped: source pins unreadable"])
        XCTAssertEqual(try storePins(t), [])
    }

    func testFormatRefusalSetsPanelProblem() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [], lsVersion: "2")
        let lines = runLaunchSync(t, s)
        XCTAssertEqual(lines.problems.count, 1)
        XCTAssertNotNil(lines.problems[0])
        XCTAssertEqual(lines.errors, ["Pin sync for 'T' failed: pin store format not recognised"])
        XCTAssertEqual(try storePins(t), [], "nothing was written")
    }

    func testMissingPinRecordInTargetSetsPanelProblem() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [], hasPinRecord: false)
        let lines = runLaunchSync(t, s)
        XCTAssertEqual(lines.problems.count, 1)
        XCTAssertNotNil(lines.problems[0])
        XCTAssertEqual(lines.errors, ["Pin sync for 'T' failed: no pin record yet"])
    }

    func testAFailedRestoreStopsTheLaunchAndNamesTheBackup() throws {
        defer { ClaudePinStore.beforeIndexedDBWrite = nil }
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_b", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_a"])
        ClaudePinStore.beforeIndexedDBWrite = {
            // Breaks the IndexedDB append and the restore: the backup folder disappears.
            let log = ClaudeStoreFixture.idbFolder(t).appendingPathComponent("000003.log")
            let h = try FileHandle(forWritingTo: log); defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: Data([1, 2, 3]))
            try FileManager.default.removeItem(at: self.backupsDir)
            try FileManager.default.createDirectory(at: self.backupsDir, withIntermediateDirectories: true)
        }
        let lines = runLaunchSync(t, s)
        let stop = try XCTUnwrap(lines.stop, "the launch must not go on")
        XCTAssertEqual(stop.logReason, "pin store restore failed")
        XCTAssertTrue(stop.message.contains(backupsDir.path), "the message names where the backup is")
        XCTAssertEqual(lines.errors, ["Pin sync for 'T' failed: pin store restore failed"])
    }

    func testEveryOtherFailureLetsTheLaunchGoOn() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [], lsVersion: "2")
        XCTAssertNil(runLaunchSync(t, s).stop)
        let u = try profile("U", chats: ["local_a"], pins: [], hasPinRecord: false)
        XCTAssertNil(runLaunchSync(u, s).stop)
    }

    func testEachPersistentLevelDBRefusalMapsToTheNote() throws {
        let t = try profile("T", chats: [], pins: [])
        for reason in ["leveldb read failed", "leveldb log not clean", "leveldb lock missing", "leveldb current log missing"] {
            XCTAssertEqual(Switcher.pinSyncNote(for: SwitcherError("x", logReason: reason), target: t),
                           "Claude's pin storage in 'T' could not be read safely, so pins were not synced there.", reason)
        }
        for reason in ["store is locked", "leveldb several live logs", "pin store write failed", "profile is open"] {
            XCTAssertNil(Switcher.pinSyncNote(for: SwitcherError("x", logReason: reason), target: t), reason)
        }
    }

    func testAMissingLockSetsTheNoteInTheLaunchPath() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [])
        try FileManager.default.removeItem(at: ClaudeStoreFixture.lsFolder(t).appendingPathComponent("LOCK"))
        let lines = runLaunchSync(t, s)
        XCTAssertEqual(lines.problemIDs, ["T"])
        XCTAssertEqual(lines.problems, ["Claude's pin storage in 'T' could not be read safely, so pins were not synced there."])
        XCTAssertEqual(lines.errors, ["Pin sync for 'T' failed: leveldb lock missing"])
        XCTAssertNil(lines.stop)
    }

    func testNotesArePerProfile() {
        let notes = PinSyncNotes()
        notes.set("A", "note A")
        notes.set("B", "note B")
        notes.set("B", nil)   // a success on B
        XCTAssertEqual(notes.all, ["A": "note A"], "B's success does not clear A's note")
        notes.set("A", nil)
        XCTAssertTrue(notes.all.isEmpty)
    }

    func testTheLaunchPathReportsTheTargetsOwnId() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: ["local_a"])
        let lines = runLaunchSync(t, s)   // nothing to change: T was read, its note is cleared
        XCTAssertEqual(lines.problemIDs, ["T"])
        XCTAssertEqual(lines.problems.count, 1)
        XCTAssertNil(lines.problems[0])
    }

    func testOtherFailuresOnlyLog() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [])
        // The target's database is locked by another process: refused, logged, no problem for the panel.
        // fcntl locks are per process, so the lock is held by a child process.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,time\nf=open(sys.argv[1],'a+')\nfcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nprint('ok',flush=True)\ntime.sleep(30)",
                           ClaudeStoreFixture.lsFolder(t).appendingPathComponent("LOCK").path]
        let out = Pipe(); child.standardOutput = out
        try child.run(); defer { child.terminate() }
        XCTAssertEqual(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        let lines = runLaunchSync(t, s)
        XCTAssertEqual(lines.errors, ["Pin sync for 'T' failed: store is locked"])
        XCTAssertFalse(lines.problems.contains { $0 != nil })
    }

    func testLaunchLogsMirrorFailureWithoutIdsAndStillReportsTheSync() throws {
        let s = try profile("S", chats: ["local_secret"], pins: ["local_secret"])
        let t = try profile("T", chats: ["local_secret"], pins: [])
        try Data("not json".utf8).write(to: ChatTransfer.configFile(t))
        let lines = runLaunchSync(t, s)   // returns normally: the launch goes on
        XCTAssertEqual(lines.info, ["Pins synced from 'S' to 'T' (1 pinned, 0 unpinned)"])
        XCTAssertEqual(lines.errors, ["Pin sync for 'T': config mirror not updated"])
        assertPathFree(lines.errors[0])
        XCTAssertEqual(try storePins(t), ["local_secret"])
        XCTAssertEqual(try String(contentsOf: ChatTransfer.configFile(t)), "not json")
    }

    private func assertPathFree(_ line: String, file: StaticString = #filePath, line l: UInt = #line) {
        XCTAssertFalse(line.contains("/"), "no path in the log: \(line)", file: file, line: l)
        XCTAssertFalse(line.contains("~"), "no home marker in the log: \(line)", file: file, line: l)
        XCTAssertFalse(line.contains("local_"), file: file, line: l)
    }

    func testLoggedReasonsOfTheKnownFailures() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("My Profile", chats: ["local_a"], pins: [])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer, logError: { _ in }).change)
        func reason(_ body: () throws -> Void) -> String? {
            do { try body(); return nil } catch { return (error as? SwitcherError)?.logReason }
        }
        XCTAssertEqual(reason { try self.apply(plan, to: t, openFolders: [t.path]) }, "profile is open")
        XCTAssertEqual(reason { try self.transfer.writePins(["local_a"], to: t, openFolders: [t.path]) }, "config belongs to an open profile")
        _ = try ClaudePinStore.write(["local_zzz"], to: t, backups: backupsDir)   // pins change under the plan
        XCTAssertEqual(reason { try self.apply(plan, to: t) }, "pins changed since planning")
        for r in ["profile is open", "config belongs to an open profile", "pins changed since planning"] { assertPathFree(r) }
    }

    func testUnknownErrorsAreLoggedAsDomainAndCode() {
        XCTAssertEqual(Switcher.describe(NSError(domain: "NSCocoaErrorDomain", code: 513)), "NSCocoaErrorDomain 513")
    }

    func testSyncPinsSettingDefaultsOn() throws {
        let settings = Settings(file: home.appendingPathComponent("settings.json"))
        XCTAssertTrue(settings.syncPins)
        try settings.set("SyncPins", false)
        XCTAssertFalse(settings.syncPins)
        try settings.set("SyncPins", true)
        XCTAssertTrue(settings.syncPins)
    }
}
