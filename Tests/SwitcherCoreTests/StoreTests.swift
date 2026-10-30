import XCTest
@testable import SwitcherCore

final class ProfileStoreTests: XCTestCase {
    var home: URL!
    var running: [String: pid_t] = [:]
    var store: ProfileStore!

    override func setUpWithError() throws {
        Lang.turkish = false
        home = try tempDir()
        let paths = Paths(home: home)
        try FileManager.default.createDirectory(at: paths.defaultProfile, withIntermediateDirectories: true)
        store = ProfileStore(paths: paths, settings: Settings(file: paths.settingsFile)) { [unowned self] in self.running }
        store.remove = { try FileManager.default.removeItem(at: $0) }
    }

    func testListsDefaultFirstThenProfiles() throws {
        _ = try store.create(name: "Work")
        _ = try store.create(name: "Account 10")
        _ = try store.create(name: "Account 2")
        // Not ours: wrong prefix, a plain file, and a symlink.
        try FileManager.default.createDirectory(at: store.paths.appSupport.appendingPathComponent("Other"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.paths.appSupport.appendingPathComponent("ClaudeProfile-File").path, contents: Data())
        try FileManager.default.createSymbolicLink(at: store.paths.appSupport.appendingPathComponent("ClaudeProfile-Link"), withDestinationURL: home)
        XCTAssertEqual(store.ids(), ["Default", "Account 2", "Account 10", "Work"])
    }

    func testNamesAreValidatedCaseInsensitively() throws {
        _ = try store.create(name: "Work")
        XCTAssertNotNil(store.validateName("work"))
        XCTAssertNotNil(store.validateName("default"))
        XCTAssertNotNil(store.validateName(""))
        XCTAssertNotNil(store.validateName("a/b"))
        XCTAssertNotNil(store.validateName("a:b"))
        XCTAssertNotNil(store.validateName(".hidden"))
        XCTAssertNotNil(store.validateName(" Work2"))
        XCTAssertNotNil(store.validateName(String(repeating: "x", count: 41)))
        XCTAssertNil(store.validateName("Personal"))
        XCTAssertNil(store.validateName("WORK", exceptID: "Work"), "renaming to a case variant of its own name is fine")
        XCTAssertEqual(store.nextAccountName(), "Account 2")
    }

    func testRenameChangesOnlyTheLabel() throws {
        let work = try store.create(name: "Work")
        let renamed = try store.rename(work, to: "Office")
        XCTAssertEqual(renamed.id, "Work")
        XCTAssertEqual(store.resolve("Office")?.id, "Work")
        XCTAssertEqual(store.resolve("Work")?.name, "Office")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.profileDir(id: "Work").path))
    }

    func testIsInsideFollowsSymlinksAndCase() throws {
        let fm = FileManager.default
        try Data().write(to: home.appendingPathComponent("probe"))
        try XCTSkipUnless(fm.fileExists(atPath: home.appendingPathComponent("PROBE").path), "case-sensitive volume")
        let folder = home.appendingPathComponent("Folder"), other = home.appendingPathComponent("Other")
        for dir in [folder, other] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data().write(to: folder.appendingPathComponent("config.json"))
        let link = home.appendingPathComponent("link.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("config.json"))
        XCTAssertTrue(ProfileStore.isInside(link, home.appendingPathComponent("FOLDER")))
        XCTAssertFalse(ProfileStore.isInside(link, other))
        XCTAssertFalse(ProfileStore.isInside(folder, folder.appendingPathComponent("config.json")), "a folder is not inside its own file")
    }

    func testRunningMapMarksProfiles() throws {
        let work = try store.create(name: "Work")
        running = [ProfileStore.key(work.path): 42, ProfileStore.key(store.paths.defaultProfile): 7]
        let list = store.list()
        XCTAssertEqual(list.first { $0.id == "Work" }?.pid, 42)
        XCTAssertEqual(list.first { $0.isDefault }?.pid, 7)
    }

    func testDeleteGuards() throws {
        let work = try store.create(name: "Work")
        XCTAssertThrowsError(try store.delete(store.resolve("Default")!))
        running = [ProfileStore.key(work.path): 42]
        XCTAssertThrowsError(try store.delete(work), "an open profile is never deleted")
        running = [:]
        let outside = Profile(id: "Work", name: "Work", path: home.appendingPathComponent("elsewhere/ClaudeProfile-Work"))
        XCTAssertThrowsError(try store.delete(outside), "only folders directly under Application Support")
        _ = try store.rename(work, to: "Office")
        try store.delete(work)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path.path))
        XCTAssertNil(store.store_label("Work"))
    }

    func testDeleteRefusesWhileSettingsAreInvalid() throws {
        let work = try store.create(name: "Work")
        try FileManager.default.createDirectory(at: store.paths.settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{".write(to: store.paths.settingsFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.delete(work))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path.path))
    }
}

final class SettingsWriteTests: XCTestCase {
    var folder: URL!
    var settingsFile: URL!
    var settings: Settings!

    override func setUpWithError() throws {
        Lang.turkish = false
        folder = try tempDir()
        settingsFile = folder.appendingPathComponent("settings.json")
        settings = Settings(file: settingsFile)
    }

    override func tearDown() {
        chmod(folder.path, 0o700)
    }

    func testSetThrowsAndLeavesAnInvalidFileAlone() throws {
        try "{".write(to: settingsFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try settings.set("A", 1))
        XCTAssertEqual(try String(contentsOf: settingsFile), "{")
    }

    func testSetThrowsWhenTheFolderIsNotWritable() throws {
        try settings.set("A", 1)
        chmod(folder.path, 0o500)
        defer { chmod(folder.path, 0o700) }
        XCTAssertThrowsError(try settings.set("B", 2))
    }

    func testConcurrentSettersKeepEveryKey() throws {
        // Two instances on one file, like the app and a command line run.
        let a = Settings(file: settingsFile), b = Settings(file: settingsFile)
        let group = DispatchGroup()
        for (settings, prefix) in [(a, "a"), (b, "b")] {
            DispatchQueue.global().async(group: group) {
                for i in 0..<50 { try? settings.set("\(prefix)\(i)", i) }
            }
        }
        group.wait()
        XCTAssertEqual(Settings(file: settingsFile).all().count, 100)
    }
}

private extension ProfileStore {
    func store_label(_ id: String) -> String? { settings.labels[id] }
}

final class ChatTransferTests: XCTestCase {
    var home: URL!
    var source: Profile!
    var target: Profile!
    var transfer: ChatTransfer!

    let acctA = "11111111-1111-1111-1111-111111111111", orgA = "22222222-2222-2222-2222-222222222222"
    let acctB = "33333333-3333-3333-3333-333333333333", orgB = "44444444-4444-4444-4444-444444444444"

    override func setUpWithError() throws {
        home = try tempDir()
        let paths = Paths(home: home)
        source = Profile(id: "Default", name: "Default", path: paths.defaultProfile)
        target = Profile(id: "Work", name: "Work", path: paths.profileDir(id: "Work"))
        transfer = ChatTransfer(transcriptsRoot: paths.transcriptsRoot)
        try FileManager.default.createDirectory(at: storeDir(source, acctA, orgA), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir(target, acctB, orgB), withIntermediateDirectories: true)
        try write(target.path.appendingPathComponent("config.json"), ["lastKnownAccountUuid": acctB])
    }

    func storeDir(_ p: Profile, _ acct: String, _ org: String) -> URL {
        ChatTransfer.sessionRoot(p).appendingPathComponent(acct).appendingPathComponent(org)
    }

    func write(_ url: URL, _ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func record(_ id: String, cli: String, title: String = "T", extra: [String: Any] = [:]) throws {
        var raw: [String: Any] = ["sessionId": "local_\(id)", "cliSessionId": cli, "title": title, "cwd": "/Users/x/proj",
                                  "bridgeSessionIds": ["cse_old"], "scheduledTaskId": "task-1", "isStarred": true, "lastActivityAt": 1_700_000_000_000]
        raw.merge(extra) { $1 }
        try write(storeDir(source, acctA, orgA).appendingPathComponent("local_\(id).json"), raw)
        try write(home.appendingPathComponent(".claude/projects/-Users-x-proj/\(cli).jsonl"), [:])
    }

    func testListsAndCopiesWithAccountFieldsReset() throws {
        try record("s1", cli: "c1", title: "First", extra: ["unknownField": ["a": 1]])
        let sessions = transfer.sessions(in: source)
        XCTAssertEqual(sessions.map(\.title), ["First"])
        XCTAssertTrue(sessions[0].hasTranscript)
        XCTAssertEqual(sessions[0].folder, "proj")

        var store = try XCTUnwrap(transfer.targetStore(for: target))
        XCTAssertEqual(store.dir.lastPathComponent, orgB)
        XCTAssertEqual(transfer.copy(sessions[0], to: &store), .copied)
        XCTAssertEqual(transfer.copy(sessions[0], to: &store), .alreadyThere)

        let copied = try JSONSerialization.jsonObject(with: Data(contentsOf: store.dir.appendingPathComponent("local_s1.json"))) as! [String: Any]
        XCTAssertEqual(copied["sessionId"] as? String, "local_s1", "the id is kept, so pins and resumes keep working")
        XCTAssertEqual((copied["bridgeSessionIds"] as? [Any])?.count, 0)
        XCTAssertNil(copied["scheduledTaskId"])
        XCTAssertEqual(copied["isStarred"] as? Bool, true)
        XCTAssertNotNil(copied["unknownField"], "fields the switcher does not know are kept")
    }

    func testSessionCarriesWorktreePath() throws {
        try record("w1", cli: "cw1", title: "Tree", extra: ["worktreePath": "/Users/x/proj/.claude/worktrees/a"])
        try record("w2", cli: "cw2", title: "Plain")
        try record("w3", cli: "cw3", title: "Empty", extra: ["worktreePath": ""])
        let byTitle = Dictionary(uniqueKeysWithValues: transfer.sessions(in: source).map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Tree"]?.worktreePath, "/Users/x/proj/.claude/worktrees/a")
        XCTAssertNil(byTitle["Plain"]?.worktreePath)
        XCTAssertNil(byTitle["Empty"]?.worktreePath, "an empty path counts as none")
    }

    // MARK: Missing parent chats

    func parented(_ id: String, _ parent: String?, detached: Bool = false) throws {
        var extra: [String: Any] = [:]
        if let parent { extra["spawnedFrom"] = ["sessionId": "local_\(parent)"] }
        if detached { extra["lineageDetached"] = true }
        try record(id, cli: "c-\(id)", title: id, extra: extra)
    }

    func ancestorIDs(pick: [String]) -> [String] {
        let all = transfer.sessions(in: source)
        let picked = all.filter { pick.contains($0.sessionID) }
        return transfer.missingAncestors(of: picked, from: source, to: target).map { "local_\($0.sessionID)" }
    }

    func testMissingAncestorsStopAtTheFirstOneTheTargetHas() throws {
        try parented("A", nil); try parented("B", "A"); try parented("C", "B")
        try write(storeDir(target, acctB, orgB).appendingPathComponent("local_A.json"), ["sessionId": "local_A"])
        XCTAssertEqual(ancestorIDs(pick: ["C"]), ["local_B"])
    }

    func testMissingAncestorsAreRootFirst() throws {
        try parented("A", nil); try parented("B", "A"); try parented("C", "B")
        XCTAssertEqual(ancestorIDs(pick: ["C"]), ["local_A", "local_B"])
    }

    func testDetachedLineageIsNotFollowed() throws {
        try parented("A", nil); try parented("B", "A", detached: true); try parented("C", "B")
        XCTAssertEqual(ancestorIDs(pick: ["B"]), [], "a detached chat shows at the top level, so its parent is not needed")
        XCTAssertEqual(ancestorIDs(pick: ["C"]), ["local_B"], "the walk stops at the detached B: A is not followed")
    }

    func testDeletedInTargetIsNotRevived() throws {
        try parented("A", nil); try parented("B", "A"); try parented("C", "B")
        FileManager.default.createFile(atPath: storeDir(target, acctB, orgB).appendingPathComponent("deleted_B").path, contents: Data())
        XCTAssertEqual(ancestorIDs(pick: ["C"]), [])
    }

    func testAncestorMissingInSourceStops() throws {
        try parented("C", "B")
        XCTAssertEqual(ancestorIDs(pick: ["C"]), [])
    }

    func testCycleAndPickedDuplicatesAreHandled() throws {
        try parented("A", "C"); try parented("B", "A"); try parented("C", "B")
        XCTAssertEqual(Set(ancestorIDs(pick: ["B", "C"])), ["local_A"])
    }

    func testSkipRules() throws {
        try record("del", cli: "c-del")
        try record("gone", cli: "c-gone")
        try record("taken", cli: "c-taken")
        try record("resumed", cli: "c-new", extra: ["priorCliSessionIds": ["c-old"]])
        try record("nocli", cli: "")
        FileManager.default.createFile(atPath: storeDir(source, acctA, orgA).appendingPathComponent("deleted_gone").path, contents: Data())
        let tdir = storeDir(target, acctB, orgB)
        FileManager.default.createFile(atPath: tdir.appendingPathComponent("deleted_del.json").path, contents: Data())
        try write(tdir.appendingPathComponent("local_taken.json"), ["cliSessionId": "someone-else"])
        try write(tdir.appendingPathComponent("local_other.json"), ["cliSessionId": "x", "priorCliSessionIds": ["c-old"]])

        let sessions = Dictionary(uniqueKeysWithValues: transfer.sessions(in: source).map { ($0.sessionID, $0) })
        XCTAssertNil(sessions["gone"], "a chat deleted in the source is not offered")
        var store = try XCTUnwrap(transfer.targetStore(for: target))
        XCTAssertEqual(transfer.copy(sessions["del"]!, to: &store), .deletedInTarget)
        XCTAssertEqual(transfer.copy(sessions["taken"]!, to: &store), .nameConflict)
        XCTAssertEqual(transfer.copy(sessions["resumed"]!, to: &store), .alreadyThere)
        XCTAssertEqual(transfer.copy(sessions["nocli"]!, to: &store), .noCLISession)
        let untouched = try JSONSerialization.jsonObject(with: Data(contentsOf: tdir.appendingPathComponent("local_taken.json"))) as! [String: Any]
        XCTAssertEqual(untouched["cliSessionId"] as? String, "someone-else", "an existing file is never overwritten")
    }

    func pinConfig(_ pins: [String], extra: [String: Any] = [:]) -> [String: Any] {
        var epitaxy: [String: Any] = ["starred-local-code-sessions": pins, "fastMode": true]
        epitaxy.merge(extra) { $1 }
        return ["coworkUserFilesPath": "/x", "preferences": ["epitaxyPrefs": epitaxy, "sidebarMode": "code"],
                "mcpServers": ["demo": ["command": "/bin/echo", "args": ["hi"]]]]
    }

    func backups(of config: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: config.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(config.lastPathComponent + ".switcher-backup-") }
    }

    func assertWritePinsRefuses(_ config: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let url = ChatTransfer.configFile(target)
        try write(url, config)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try transfer.writePins(["local_1"], to: target), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), original, file: file, line: line)
        XCTAssertTrue(try backups(of: url).isEmpty, "a refused file gets no backup", file: file, line: line)
    }

    func testWritePinsRefusesWhenPreferencesIsNotAnObject() throws {
        try assertWritePinsRefuses(["mcpServers": ["x": [String: Any]()], "preferences": "oops"])
    }

    func testWritePinsRefusesWhenEpitaxyPrefsIsNotAnObject() throws {
        try assertWritePinsRefuses(["mcpServers": ["x": [String: Any]()], "preferences": ["epitaxyPrefs": [1]]])
    }

    func testWritePinsKeepsMcpServers() throws {
        let url = ChatTransfer.configFile(target)
        try write(url, pinConfig(["local_old"]))
        try transfer.writePins(["local_1"], to: target)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual((root["mcpServers"] as? [String: Any])?.keys.sorted(), ["demo"])
        XCTAssertEqual(transfer.pins(of: target), ["local_1"])
    }

    // MARK: Carrying pins into Claude's own store

    func storeProfile(_ id: String, pins: [String]?, config: String? = "{\"mcpServers\":{\"x\":1}}") throws -> Profile {
        try ClaudeStoreFixture.makeProfile(in: home, id: id, name: id, starredIds: pins, pinnedOrder: (pins ?? []).map { "code:" + $0 },
                                           listMirror: pins ?? [], config: config)
    }

    func sessionsNamed(_ ids: [String]) -> [CodeSession] {
        ids.map { CodeSession(file: home.appendingPathComponent("local_\($0).json"), sessionID: $0, cliSessionID: "c\($0)",
                              priorCLISessionIDs: [], title: $0, folder: "", updated: Date(), hasTranscript: true) }
    }

    var pinBackups: URL { home.appendingPathComponent("backups/pinstore") }

    func testCarriedPinsGoOnTopInSourceOrder() throws {
        let src = try storeProfile("S", pins: ["local_b", "local_a", "local_d"])   // d is not copied
        let dst = try storeProfile("T", pins: ["local_x", "local_a"])
        let carried = try transfer.carryPins(of: sessionsNamed(["a", "b", "c"]), from: src, to: dst, backups: pinBackups, logError: { _ in })
        XCTAssertEqual(carried, 2)
        XCTAssertEqual(try ClaudePinStore.read(dst, tolerateTornTail: false)?.sidebar, ["local_b", "local_a", "local_x"],
                       "carried pins on top in the source's order, the target's others after, no duplicates")
        XCTAssertEqual(transfer.pins(of: dst), ["local_b", "local_a", "local_x"], "the config mirror follows")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: ChatTransfer.configFile(dst))) as! [String: Any]
        XCTAssertNotNil(root["mcpServers"], "everything else in the config is kept")
    }

    func testCarryPinsStarsTheCopiedRecords() throws {
        let src = try storeProfile("S", pins: ["local_a"])
        let dst = try storeProfile("T", pins: [])
        let dir = ChatTransfer.sessionRoot(dst).appendingPathComponent("acct/org")
        try write(dir.appendingPathComponent("local_a.json"), ["sessionId": "local_a", "cliSessionId": "ca"])
        XCTAssertEqual(try transfer.carryPins(of: sessionsNamed(["a"]), from: src, to: dst, backups: pinBackups, logError: { _ in }), 1)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("local_a.json"))) as! [String: Any]
        XCTAssertEqual(raw["isStarred"] as? Bool, true)
    }

    func testCarryPinsRefusalLeavesChatsCopied() throws {
        let src = try storeProfile("S", pins: ["local_a"])
        let noRecord = try storeProfile("T", pins: nil)
        let before = try ClaudeStoreFixture.snapshot(noRecord.path.appendingPathComponent("IndexedDB"))
        XCTAssertThrowsError(try transfer.carryPins(of: sessionsNamed(["a"]), from: src, to: noRecord, backups: pinBackups, logError: { _ in })) {
            XCTAssertEqual(($0 as? SwitcherError)?.logReason, "no pin record yet")
        }
        XCTAssertEqual(try ClaudeStoreFixture.snapshot(noRecord.path.appendingPathComponent("IndexedDB")), before, "nothing was written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinBackups.path))
    }

    func testCarryPinsRefusesAnOpenTarget() throws {
        let src = try storeProfile("S", pins: ["local_a"])
        let dst = try storeProfile("T", pins: [])
        XCTAssertThrowsError(try transfer.carryPins(of: sessionsNamed(["a"]), from: src, to: dst, openFolders: [dst.path], backups: pinBackups, logError: { _ in }))
        XCTAssertEqual(try ClaudePinStore.read(dst, tolerateTornTail: false)?.sidebar, [])
    }

    func testCarryPinsFromASourceWithoutPinsCarriesNothing() throws {
        let dst = try storeProfile("T", pins: ["local_x"])
        let noRecord = try storeProfile("S", pins: nil)
        XCTAssertEqual(try transfer.carryPins(of: sessionsNamed(["a"]), from: noRecord, to: dst, backups: pinBackups, logError: { _ in }), 0)
        let unreadable = try storeProfile("U", pins: ["local_a"])
        try FileManager.default.removeItem(at: ClaudeStoreFixture.idbFolder(unreadable))
        var logged = [String]()
        XCTAssertEqual(try transfer.carryPins(of: sessionsNamed(["a"]), from: unreadable, to: dst, backups: pinBackups, logError: { logged.append($0) }), 0)
        XCTAssertEqual(logged, ["Pins for 'T' not carried: source pins unreadable"], "one fixed line, no ids or paths")
        logged = []
        XCTAssertEqual(try transfer.carryPins(of: sessionsNamed(["a"]), from: noRecord, to: dst, backups: pinBackups, logError: { logged.append($0) }), 0)
        XCTAssertTrue(logged.isEmpty, "a source with no record is silent")
        XCTAssertEqual(try ClaudePinStore.read(dst, tolerateTornTail: false)?.sidebar, ["local_x"])
    }

    func testCarryPinsReadsASourceWithATornTail() throws {
        let src = try storeProfile("S", pins: ["local_a"])
        let log = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: ClaudeStoreFixture.lsFolder(src), includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "log" })
        let h = try FileHandle(forWritingTo: log); h.seekToEndOfFile(); h.write(Data([0x01, 0x02, 0x03])); try h.close()
        let dst = try storeProfile("T", pins: [])
        XCTAssertEqual(try transfer.carryPins(of: sessionsNamed(["a"]), from: src, to: dst, backups: pinBackups, logError: { _ in }), 1)
    }

    func testCarryPinsMirrorFailureDoesNotFailTheCarry() throws {
        let src = try storeProfile("S", pins: ["local_a"])
        let broken = "{\"mcpServers\": {\"a\": {\"command\": \"x\""   // truncated mid-edit
        let dst = try storeProfile("T", pins: [], config: broken)
        XCTAssertEqual(try transfer.carryPins(of: sessionsNamed(["a"]), from: src, to: dst, backups: pinBackups, logError: { _ in }), 1)
        XCTAssertEqual(try ClaudePinStore.read(dst, tolerateTornTail: false)?.sidebar, ["local_a"])
        XCTAssertEqual(try String(contentsOf: ChatTransfer.configFile(dst)), broken, "the user's file is left exactly as it was")
    }

    func testNoTargetStoreUntilCodeTabOpened() throws {
        let fresh = Profile(id: "New", name: "New", path: Paths(home: home).profileDir(id: "New"))
        XCTAssertNil(transfer.targetStore(for: fresh))
    }

    func testWriteNewNeverReplaces() throws {
        let file = try tempDir().appendingPathComponent("x.json")
        try ChatTransfer.writeNew(Data("1".utf8), to: file)
        XCTAssertThrowsError(try ChatTransfer.writeNew(Data("2".utf8), to: file))
        XCTAssertEqual(try String(contentsOf: file), "1")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["x.json"], "the temp file is cleaned up")
    }
}

final class ReviewFixStoreTests: XCTestCase {
    func testCreatingAProfileIsExclusive() throws {
        let paths = Paths(home: try tempDir())
        let store = ProfileStore(paths: paths, settings: Settings(file: paths.settingsFile)) { [:] }
        _ = try store.create(name: "Work")
        // A second writer that skipped validation (another process, a race) must not reuse the folder.
        XCTAssertThrowsError(try store.createFolder(id: "Work"))
    }

    func testTargetStoreFollowsTheSignedInAccountOnly() throws {
        let home = try tempDir()
        let target = Profile(id: "Work", name: "Work", path: Paths(home: home).profileDir(id: "Work"))
        let old = ChatTransfer.sessionRoot(target).appendingPathComponent("old-account/org-1")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": "new-account"]).write(to: target.path.appendingPathComponent("config.json"))
        XCTAssertNil(ChatTransfer(transcriptsRoot: home).targetStore(for: target),
                     "chats would be invisible in the old account's store: wait until the new account opened the Code tab")
    }

    func testTargetStorePicksTheOrganisationInUse() throws {
        let home = try tempDir()
        let target = Profile(id: "Work", name: "Work", path: Paths(home: home).profileDir(id: "Work"))
        let root = ChatTransfer.sessionRoot(target).appendingPathComponent("acct")
        for org in ["org-old", "org-new"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(org), withIntermediateDirectories: true) }
        let oldRecord = root.appendingPathComponent("org-old/local_1.json")
        let newRecord = root.appendingPathComponent("org-new/local_2.json")
        try Data("{}".utf8).write(to: oldRecord)
        try Data("{}".utf8).write(to: newRecord)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: oldRecord.path)
        // The older organisation's folder itself was touched last; the records say otherwise.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: root.appendingPathComponent("org-old").path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: root.appendingPathComponent("org-new").path)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": "acct"]).write(to: target.path.appendingPathComponent("config.json"))
        let store = try XCTUnwrap(ChatTransfer(transcriptsRoot: home).targetStore(for: target))
        XCTAssertEqual(store.dir.lastPathComponent, "org-new")
        XCTAssertEqual(store.organisationCount, 2)
    }
}
