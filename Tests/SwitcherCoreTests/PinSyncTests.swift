import XCTest
@testable import SwitcherCore

final class PinSyncTests: XCTestCase {
    var home: URL!
    var transfer: ChatTransfer!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pinsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        transfer = ChatTransfer(transcriptsRoot: home.appendingPathComponent("transcripts"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func profile(_ id: String, chats: [String], pins: [String], deleted: [String] = [], starred: Set<String>? = nil, org: String = "org") throws -> Profile {
        let p = Profile(id: id, name: id, path: home.appendingPathComponent(id))
        let dir = ChatTransfer.sessionRoot(p).appendingPathComponent("acct").appendingPathComponent(org)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stars = starred ?? Set(pins)
        for c in chats {
            var obj: [String: Any] = ["sessionId": c, "title": c, "cliSessionId": "cli-\(c)"]
            if stars.contains(c) { obj["isStarred"] = true }
            try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("\(c).json"))
        }
        for d in deleted { try Data().write(to: dir.appendingPathComponent("deleted_\(d)")) }
        let cfg: [String: Any] = ["mcpServers": ["x": 1], "preferences": ["epitaxyPrefs": ["starred-local-code-sessions": pins, "other": 5]]]
        try JSONSerialization.data(withJSONObject: cfg).write(to: ChatTransfer.configFile(p))
        return p
    }

    func record(_ p: Profile, _ id: String, org: String = "org") throws -> [String: Any] {
        let f = ChatTransfer.sessionRoot(p).appendingPathComponent("acct/\(org)/\(id).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
    }

    func backups(_ dir: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains("switcher-backup") }
    }

    func testNewListFollowsSourceOrderThenTargetOnlyPins() throws {
        let s = try profile("S", chats: ["local_a", "local_b", "local_c"], pins: ["local_c", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_b", "local_c", "local_t"], pins: ["local_t", "local_b"], starred: ["local_t", "local_b"])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer))
        XCTAssertEqual(plan.source, "S")
        // local_t is not in the source, so it stays after the source's pins; local_b is shared and unpinned in the source
        XCTAssertEqual(plan.newPins, ["local_c", "local_a", "local_t"])
        XCTAssertEqual(Set(plan.star), ["local_a", "local_c"])
        XCTAssertEqual(plan.unstar, ["local_b"])
        try PinSync.apply(plan, to: t, transfer: transfer, openFolders: [])
        XCTAssertEqual(transfer.pins(of: t), ["local_c", "local_a", "local_t"])
    }

    func testUnpinnedInSourceIsUnpinnedInTarget() throws {
        let s = try profile("S", chats: ["local_a"], pins: [])
        let t = try profile("T", chats: ["local_a"], pins: ["local_a"])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer))
        XCTAssertEqual(plan.newPins, [])
        XCTAssertEqual(plan.unstar, ["local_a"])
        try PinSync.apply(plan, to: t, transfer: transfer, openFolders: [])
        XCTAssertEqual(transfer.pins(of: t), [])
        XCTAssertEqual(try record(t, "local_a")["isStarred"] as? Bool, false)
    }

    func testOnlyChatsInBothProfilesAreTouched() throws {
        let s = try profile("S", chats: ["local_a", "local_s"], pins: ["local_s", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_t"], pins: ["local_t"])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer))
        XCTAssertEqual(plan.newPins, ["local_a", "local_t"], "local_s is not in the target and is not brought along")
        XCTAssertEqual(plan.star, ["local_a"])
        XCTAssertEqual(plan.unstar, [])
        try PinSync.apply(plan, to: t, transfer: transfer, openFolders: [])
        XCTAssertEqual(try record(t, "local_t")["isStarred"] as? Bool, true)
    }

    func testDeletedChatsAreIgnored() throws {
        let s = try profile("S", chats: ["local_a", "local_d"], pins: ["local_d", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_d"], pins: [], deleted: ["d"])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer))
        XCTAssertEqual(plan.newPins, ["local_a"])
        XCTAssertEqual(plan.star, ["local_a"])
    }

    func testNoChangeWritesNothing() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_a", "local_b"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_a", "local_b"])
        XCTAssertNil(PinSync.plan(target: t, source: s, transfer: transfer))
        XCTAssertEqual(backups(t.path), [])
    }

    func testRecordsGetIsStarredUpdated() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_b"])
        // the same chat also sits in a second organisation folder
        let second = ChatTransfer.sessionRoot(t).appendingPathComponent("acct/org2")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_a", "extra": 1]).write(to: second.appendingPathComponent("local_a.json"))
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer))
        try PinSync.apply(plan, to: t, transfer: transfer, openFolders: [])
        XCTAssertEqual(try record(t, "local_a")["isStarred"] as? Bool, true)
        XCTAssertEqual(try record(t, "local_a", org: "org2")["isStarred"] as? Bool, true)
        XCTAssertEqual(try record(t, "local_a", org: "org2")["extra"] as? Int, 1, "other fields kept")
        XCTAssertEqual(try record(t, "local_b")["isStarred"] as? Bool, false)
        XCTAssertEqual(try record(t, "local_b")["title"] as? String, "local_b")
        XCTAssertFalse(backups(ChatTransfer.sessionRoot(t)).isEmpty, "records are backed up before being written")
        XCTAssertFalse(backups(t.path).filter { $0.hasPrefix("claude_desktop_config") }.isEmpty)
        let mode = (try FileManager.default.attributesOfItem(atPath: ChatTransfer.sessionRoot(t).appendingPathComponent("acct/org/local_a.json").path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: ChatTransfer.configFile(t))) as! [String: Any]
        XCTAssertNotNil(cfg["mcpServers"], "other config keys kept")
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

    func testUnreadableConfigWritesNothing() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [])
        let broken = Data(#"{"mcpServers": {"#.utf8)
        try broken.write(to: ChatTransfer.configFile(t))
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer))
        XCTAssertThrowsError(try PinSync.apply(plan, to: t, transfer: transfer, openFolders: []))
        XCTAssertEqual(try Data(contentsOf: ChatTransfer.configFile(t)), broken)
        XCTAssertNil(try record(t, "local_a")["isStarred"], "records are untouched too")
        XCTAssertEqual(backups(t.path), [])
    }

    func testOpenTargetIsRefused() throws {
        let s = try profile("S", chats: ["local_a"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a"], pins: [])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer))
        XCTAssertThrowsError(try PinSync.apply(plan, to: t, transfer: transfer, openFolders: [t.path]))
        XCTAssertEqual(transfer.pins(of: t), [])
        XCTAssertNil(try record(t, "local_a")["isStarred"])
    }

    func testStalePlanIsRefused() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: [])
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer))
        try transfer.writePins(["local_b"], to: t)
        XCTAssertThrowsError(try PinSync.apply(plan, to: t, transfer: transfer, openFolders: []))
        XCTAssertEqual(transfer.pins(of: t), ["local_b"])
        XCTAssertNil(try record(t, "local_a")["isStarred"])
    }

    func testPartialRecordFailureIsHealedNextTime() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_a", "local_b"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: [])
        let locked = ChatTransfer.sessionRoot(t).appendingPathComponent("acct/org2")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_b"]).write(to: locked.appendingPathComponent("local_b.json"))
        let plan = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer))
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o700) }
        XCTAssertThrowsError(try PinSync.apply(plan, to: t, transfer: transfer, openFolders: [])) { error in
            XCTAssertTrue((error as? SwitcherError)?.message.contains("1") == true)
            XCTAssertTrue((error as? SwitcherError)?.message.contains("pin list was written") == true)
        }
        XCTAssertEqual(transfer.pins(of: t), ["local_a", "local_b"], "the list is written")
        XCTAssertEqual(try record(t, "local_a")["isStarred"] as? Bool, true, "the other records were still written")
        chmod(locked.path, 0o700)
        let again = try XCTUnwrap(PinSync.plan(target: t, source: s, transfer: transfer), "the unchanged list still has a mismatch to heal")
        XCTAssertEqual(again.newPins, ["local_a", "local_b"])
        XCTAssertEqual(again.star, ["local_b"])
        try PinSync.apply(again, to: t, transfer: transfer, openFolders: [])
        XCTAssertEqual(try record(t, "local_b", org: "org2")["isStarred"] as? Bool, true)
        XCTAssertNil(PinSync.plan(target: t, source: s, transfer: transfer))
    }

    func testUnstarRecordWithoutKey() throws {
        let s = try profile("S", chats: ["local_a"], pins: [])
        let t = try profile("T", chats: ["local_a"], pins: [], starred: [])
        XCTAssertNil(PinSync.plan(target: t, source: s, transfer: transfer), "an absent key already means not starred")
        let u = try profile("U", chats: ["local_a"], pins: ["local_a"], starred: [])
        let plan = try XCTUnwrap(PinSync.plan(target: u, source: s, transfer: transfer))
        try PinSync.apply(plan, to: u, transfer: transfer, openFolders: [])
        XCTAssertNil(try record(u, "local_a")["isStarred"], "no write needed for a record without the key")
        XCTAssertEqual(transfer.pins(of: u), [])
    }

    // MARK: Launch path

    final class Lines { var info: [String] = []; var errors: [String] = [] }

    func runLaunchSync(_ t: Profile, _ s: Profile, enabled: Bool = true, open: [URL] = [], lines: Lines = Lines()) -> Lines {
        let now = Date()
        Switcher.syncPinsBeforeLaunch(target: t, among: [s, t], openFolders: open, enabled: enabled, transfer: transfer,
                                      lastUsed: { $0.id == "S" ? now : now.addingTimeInterval(-3600) },
                                      log: { lines.info.append($0) }, logError: { lines.errors.append($0) })
        return lines
    }

    func testLaunchSyncsPinsBeforeStartingWhenEnabled() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_b", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_a"])
        let lines = runLaunchSync(t, s)
        XCTAssertEqual(transfer.pins(of: t), ["local_b", "local_a"])
        XCTAssertEqual(lines.info, ["Pins synced from 'S' to 'T'"])
        XCTAssertTrue(lines.errors.isEmpty)
    }

    func testLaunchSkipsPinSyncWhenDisabled() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_b", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_a"])
        let lines = runLaunchSync(t, s, enabled: false)
        XCTAssertEqual(transfer.pins(of: t), ["local_a"])
        XCTAssertTrue(lines.info.isEmpty && lines.errors.isEmpty)
    }

    func testLaunchSkipsPinSyncForRunningTarget() throws {
        let s = try profile("S", chats: ["local_a", "local_b"], pins: ["local_b", "local_a"])
        let t = try profile("T", chats: ["local_a", "local_b"], pins: ["local_a"])
        let lines = runLaunchSync(t, s, open: [t.path])
        XCTAssertEqual(transfer.pins(of: t), ["local_a"])
        XCTAssertTrue(lines.info.isEmpty && lines.errors.isEmpty)
    }

    func testLaunchLogsErrorWithoutIdsAndContinues() throws {
        let s = try profile("S", chats: ["local_secret"], pins: ["local_secret"])
        let t = try profile("T", chats: ["local_secret"], pins: [])
        // The target's own config is not parseable: nothing is written, one message is logged.
        try Data("not json".utf8).write(to: ChatTransfer.configFile(t))
        let lines = runLaunchSync(t, s)
        XCTAssertTrue(lines.info.isEmpty)
        XCTAssertLessThanOrEqual(lines.errors.count, 1)
        XCTAssertFalse(lines.errors.joined().contains("local_secret"))
    }

    func testSyncPinsSettingDefaultsOn() throws {
        let settings = Settings(file: home.appendingPathComponent("settings.json"))
        XCTAssertTrue(settings.syncPins)
        settings.set("SyncPins", false)
        XCTAssertFalse(settings.syncPins)
        settings.set("SyncPins", true)
        XCTAssertTrue(settings.syncPins)
    }
}
