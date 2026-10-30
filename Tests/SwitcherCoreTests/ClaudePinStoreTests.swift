import XCTest
@testable import SwitcherCore

final class ClaudePinStoreTests: XCTestCase {
    private var root: URL!
    private var backups: URL!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pinstore-\(UUID().uuidString)")
        backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        ClaudePinStore.beforeIndexedDBWrite = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ id: String = "p1", starred: [String]? = ["local_a", "local_b"], order: [String]? = [],
                      mirror: [String]? = ["local_a", "local_b"], version: String? = "1", encoding: ClaudeStoreFixture.ValueEncoding = .byContent,
                      meta: Bool = true, dbId: UInt8 = 1) throws -> Profile {
        try ClaudeStoreFixture.makeProfile(in: root.appendingPathComponent("accounts"), id: id, starredIds: starred, pinnedOrder: order,
                                           listMirror: mirror, lsVersion: version, lsEncoding: encoding, includeMeta: meta, databaseId: dbId)
    }
    private func backupCount(_ id: String = "p1") -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: backups.appendingPathComponent($0).appendingPathComponent(id).path) }.count
    }
    private func lsJSON(_ p: Profile, _ name: String) throws -> [String: Any] {
        let e = try XCTUnwrap(LevelDBReader(folder: ClaudeStoreFixture.lsFolder(p)).newest(LocalStorageCodec.key(name)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try LocalStorageCodec.decode(e.value).utf8)) as? [String: Any])
    }
    private func order(_ p: Profile) throws -> [String]? { ((try lsJSON(p, "dframe-store")["state"]) as? [String: Any])?["pinnedOrder"] as? [String] }
    private func expectRefusal(_ reason: String, _ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual(($0 as? SwitcherError)?.logReason, reason, file: file, line: line) }
    }

    func testSidebarOrderFollowsPinnedOrderThenSortedIds() {
        XCTAssertEqual(ClaudePins(starred: ["local_c", "local_a", "local_b"], order: ["code:local_b", "cowork:x", "code:local_z"]).sidebar,
                       ["local_b", "local_a", "local_c"])
    }

    func testReadIsNilWithoutPinRecord() throws {
        XCTAssertNil(try ClaudePinStore.read(try make(starred: nil), tolerateTornTail: false))
    }

    func testReadReturnsStarredAndOrder() throws {
        let p = try make(order: ["code:local_b", "cowork:x"])
        let pins = try XCTUnwrap(ClaudePinStore.read(p, tolerateTornTail: true))
        XCTAssertEqual(pins.starred, ["local_a", "local_b"])
        XCTAssertEqual(pins.order, ["code:local_b", "cowork:x"])
        XCTAssertEqual(pins.sidebar, ["local_b", "local_a"])
    }

    func testWriteThenReadBack() throws {
        let p = try make()
        XCTAssertTrue(try ClaudePinStore.write(["local_b", "local_a"], to: p, backups: backups, now: now))
        XCTAssertEqual(try ClaudePinStore.read(p, tolerateTornTail: false)?.sidebar, ["local_b", "local_a"])
        XCTAssertEqual(try ClaudePinStore.read(p, tolerateTornTail: false)?.starred, ["local_b", "local_a"])
    }

    func testWritesEveryMirrorAndKeepsOtherFields() throws {
        let p = try make(order: ["cowork:x"])
        XCTAssertTrue(try ClaudePinStore.write(["local_c"], to: p, backups: backups, now: now))
        let ms = 1_700_000_000_000
        let mirror = try lsJSON(p, "LSS-persisted.starred-local-code-sessions")
        XCTAssertEqual(mirror["value"] as? [String], ["local_c"])
        XCTAssertEqual(mirror["timestamp"] as? Int, ms)
        XCTAssertEqual(mirror["tabId"] as? String, "")
        let store = try lsJSON(p, "dframe-store")
        XCTAssertEqual(store["version"] as? Int, 2)
        XCTAssertEqual(store["shared"] as? Bool, false)
        XCTAssertEqual((store["state"] as? [String: Any])?["theme"] as? String, "dark")
        let slice = try lsJSON(p, "LSS-persisted.dframe-local-slice")
        let value = try XCTUnwrap(slice["value"] as? [String: Any])
        XCTAssertEqual(value["pinnedOrder"] as? [String], ["code:local_c", "cowork:x"])
        XCTAssertEqual(value["homeProjectsPinnedOrder"] as? [String], ["p1"])
        XCTAssertEqual(slice["timestamp"] as? Int, ms)
        let meta = try XCTUnwrap(LevelDBReader(folder: ClaudeStoreFixture.lsFolder(p)).newest(LocalStorageCodec.metaKey))
        XCTAssertNotEqual(meta.value, Data([0x08, 0x01, 0x10, 0xF4, 0x03]))
    }

    func testPinnedOrderKeepsOtherEntriesAfter() throws {
        let p = try make(starred: ["local_old"], order: ["cowork:x", "code:local_old"], mirror: ["local_old"])
        XCTAssertTrue(try ClaudePinStore.write(["local_a"], to: p, backups: backups, now: now))
        XCTAssertEqual(try order(p), ["code:local_a", "cowork:x", "code:local_old"])
    }

    func testMovedEntryIsNotDuplicated() throws {
        let p = try make(order: ["cowork:x", "code:local_b", "code:local_a"])
        XCTAssertTrue(try ClaudePinStore.write(["local_a", "local_b"], to: p, backups: backups, now: now))
        XCTAssertEqual(try order(p), ["code:local_a", "code:local_b", "cowork:x"])
    }

    func testUTF16LocalStorageValuesAreRewrittenByContent() throws {
        let p = try make(encoding: .utf16)
        XCTAssertTrue(try ClaudePinStore.write(["local_b"], to: p, backups: backups, now: now))
        let e = try XCTUnwrap(LevelDBReader(folder: ClaudeStoreFixture.lsFolder(p)).newest(LocalStorageCodec.key("dframe-store")))
        XCTAssertEqual(e.value.first, 0x01)
        XCTAssertEqual(try order(p), ["code:local_b"])
    }

    func testNoOpWritesNothingAndTakesNoBackup() throws {
        let p = try make(order: ["code:local_b"], mirror: ["local_b", "local_a"])
        let current = try XCTUnwrap(ClaudePinStore.read(p, tolerateTornTail: false))
        XCTAssertEqual(current.sidebar, ["local_b", "local_a"])
        // starredIds is ["local_a","local_b"], so only an exact match of both is a no-op.
        XCTAssertTrue(try ClaudePinStore.write(["local_b", "local_a"], to: p, backups: backups, now: now))
        let before = try ClaudeStoreFixture.snapshot(p.path)
        let count = backupCount()
        XCTAssertFalse(try ClaudePinStore.write(["local_b", "local_a"], to: p, backups: backups, now: now))
        XCTAssertEqual(try ClaudeStoreFixture.snapshot(p.path), before)
        XCTAssertEqual(backupCount(), count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
    }

    func testNoOpFirstWriteLeavesBackupsEmpty() throws {
        let p = try make(starred: ["local_a"], order: ["code:local_a"])
        XCTAssertFalse(try ClaudePinStore.write(["local_a"], to: p, backups: backups, now: now))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }

    func testRefusesWithoutPinRecord() throws {
        let p = try make(starred: nil)
        expectRefusal("no pin record yet") { try ClaudePinStore.write(["local_a"], to: p, backups: self.backups, now: self.now) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }

    func testRefusesUnknownLocalStorageVersion() throws {
        for v in ["2", nil] as [String?] {
            let p = try make("v\(v ?? "none")", version: v)
            let before = try ClaudeStoreFixture.snapshot(p.path)
            expectRefusal("pin store format not recognised") { try ClaudePinStore.write(["local_z"], to: p, backups: self.backups, now: self.now) }
            XCTAssertEqual(try ClaudeStoreFixture.snapshot(p.path), before)
        }
    }

    func testRefusesMissingKeysAndMeta() throws {
        let cases: [(String, Profile)] = [("order", try make("o", order: nil)), ("mirror", try make("m", mirror: nil)), ("meta", try make("t", meta: false))]
        for (_, p) in cases {
            let before = try ClaudeStoreFixture.snapshot(p.path)
            expectRefusal("pin store format not recognised") { try ClaudePinStore.write(["local_z"], to: p, backups: self.backups, now: self.now) }
            XCTAssertEqual(try ClaudeStoreFixture.snapshot(p.path), before)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }

    func testRefusesUnexpectedJSONTypes() throws {
        let bad = [#"{"state":{"pinnedOrder":"nope"},"version":1}"#, #"{"state":{"pinnedOrder":[1]},"version":1}"#, #"{"state":[],"version":1}"#, "[1]"]
        for (i, text) in bad.enumerated() {
            let p = try make("j\(i)")
            let w = LevelDBWriter(folder: ClaudeStoreFixture.lsFolder(p))
            _ = try LevelDBLock.withExclusive(ClaudeStoreFixture.lsFolder(p)) { try w.append([(LocalStorageCodec.key("dframe-store"), LocalStorageCodec.encode(text))]) }
            let before = try ClaudeStoreFixture.snapshot(p.path)
            expectRefusal("pin store format not recognised") { try ClaudePinStore.write(["local_z"], to: p, backups: self.backups, now: self.now) }
            XCTAssertEqual(try ClaudeStoreFixture.snapshot(p.path), before)
        }
    }

    func testRollsBackWhenIndexedDBWriteFails() throws {
        let p = try make()
        let lsBefore = try ClaudeStoreFixture.snapshot(ClaudeStoreFixture.lsFolder(p))
        let idbBefore = try ClaudeStoreFixture.snapshot(ClaudeStoreFixture.idbFolder(p))
        ClaudePinStore.beforeIndexedDBWrite = {
            // Leaves a half record at the end of the IndexedDB log, so its append refuses.
            let log = ClaudeStoreFixture.idbFolder(p).appendingPathComponent("000003.log")
            let h = try FileHandle(forWritingTo: log); defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: Data([1, 2, 3]))
        }
        expectRefusal("pin store write failed") { try ClaudePinStore.write(["local_a"], to: p, backups: self.backups, now: self.now) }
        XCTAssertEqual(try ClaudeStoreFixture.snapshot(ClaudeStoreFixture.lsFolder(p)), lsBefore)
        XCTAssertEqual(try ClaudeStoreFixture.snapshot(ClaudeStoreFixture.idbFolder(p)), idbBefore)
    }

    func testRollbackFailureNamesTheBackup() throws {
        let p = try make()
        ClaudePinStore.beforeIndexedDBWrite = {
            // Break both the IndexedDB append and the restore: the backup folder disappears.
            let log = ClaudeStoreFixture.idbFolder(p).appendingPathComponent("000003.log")
            let h = try FileHandle(forWritingTo: log); defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: Data([1, 2, 3]))
            try FileManager.default.removeItem(at: self.backups)
            try FileManager.default.createDirectory(at: self.backups, withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try ClaudePinStore.write(["local_a"], to: p, backups: backups, now: now)) {
            let e = $0 as? SwitcherError
            XCTAssertEqual(e?.logReason, "pin store restore failed")
            XCTAssertTrue(e?.message.contains(self.backups.path) ?? false)
        }
    }

    func testBackupHoldsBothDatabasesAndConfig() throws {
        let p = try make()
        XCTAssertTrue(try ClaudePinStore.write(["local_z"], to: p, backups: backups, now: now))
        let stamp = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: backups.path).first)
        XCTAssertEqual(stamp, "20231114-221320-000")
        let dir = backups.appendingPathComponent(stamp).appendingPathComponent("p1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("claude_desktop_config.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb/000003.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Local Storage/leveldb/000003.log").path))
    }

    func testKeepsFiveBackupsPerProfile() throws {
        let p = try make(), other = try make("p2")
        XCTAssertTrue(try ClaudePinStore.write(["local_x"], to: other, backups: backups, now: now.addingTimeInterval(-1000)))
        for i in 0..<7 {
            XCTAssertTrue(try ClaudePinStore.write(["local_\(i)"], to: p, backups: backups, now: now.addingTimeInterval(Double(i))))
        }
        XCTAssertEqual(backupCount("p1"), 5)
        XCTAssertEqual(backupCount("p2"), 1)
        let kept = try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { FileManager.default.fileExists(atPath: backups.appendingPathComponent($0).appendingPathComponent("p1").path) }.sorted()
        XCTAssertEqual(kept.first, "20231114-221322-000")
    }

    func testSameInstantTwiceDoesNotCollide() throws {
        let p = try make()
        XCTAssertTrue(try ClaudePinStore.write(["local_1"], to: p, backups: backups, now: now))
        XCTAssertTrue(try ClaudePinStore.write(["local_2"], to: p, backups: backups, now: now))
        XCTAssertEqual(backupCount(), 2)
    }

    func testAcceptsOtherDatabaseId() throws {
        let p = try make(dbId: 5)
        XCTAssertTrue(try ClaudePinStore.write(["local_b"], to: p, backups: backups, now: now))
        XCTAssertEqual(try ClaudePinStore.read(p, tolerateTornTail: false)?.starred, ["local_b"])
    }

    func testRefusesWhileLocked() throws {
        let p = try make()
        let before = try ClaudeStoreFixture.snapshot(p.path)
        // fcntl locks are per process, so the lock is held by a child process.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,time\nf=open(sys.argv[1],'a+')\nfcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nprint('ok',flush=True)\ntime.sleep(30)", ClaudeStoreFixture.lsFolder(p).appendingPathComponent("LOCK").path]
        let out = Pipe(); child.standardOutput = out
        try child.run(); defer { child.terminate() }
        XCTAssertEqual(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        expectRefusal("store is locked") { try ClaudePinStore.write(["local_z"], to: p, backups: self.backups, now: self.now) }
        XCTAssertEqual(try ClaudeStoreFixture.snapshot(p.path), before)
    }

    func testNewBackupSurvivesPruneWhenClockIsBehind() throws {
        let p = try make()
        for i in 0..<5 {   // five existing copies dated after "now"
            let d = backups.appendingPathComponent("2099010\(i)-000000-000/p1")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let before = try ClaudeStoreFixture.snapshot(ClaudeStoreFixture.lsFolder(p))
        XCTAssertTrue(try ClaudePinStore.write(["local_z"], to: p, backups: backups, now: now))
        let mine = backups.appendingPathComponent("20231114-221320-000/p1")
        XCTAssertEqual(try ClaudeStoreFixture.snapshot(mine.appendingPathComponent("Local Storage/leveldb")), before)
        XCTAssertEqual(backupCount(), 5)
    }

    func testEachKeyKeepsItsOwnOtherOrderEntries() throws {
        let p = try make(order: ["cowork:x"])
        let w = LevelDBWriter(folder: ClaudeStoreFixture.lsFolder(p))
        let slice = #"{"value":{"pinnedOrder":["cowork:y","code:local_a"]},"tabId":"","timestamp":1}"#
        _ = try LevelDBLock.withExclusive(ClaudeStoreFixture.lsFolder(p)) { try w.append([(LocalStorageCodec.key("LSS-persisted.dframe-local-slice"), LocalStorageCodec.encode(slice))]) }
        XCTAssertTrue(try ClaudePinStore.write(["local_b"], to: p, backups: backups, now: now))
        XCTAssertEqual(try order(p), ["code:local_b", "cowork:x"])
        let value = try XCTUnwrap(try lsJSON(p, "LSS-persisted.dframe-local-slice")["value"] as? [String: Any])
        XCTAssertEqual(value["pinnedOrder"] as? [String], ["code:local_b", "cowork:y", "code:local_a"])
    }

    func testHeldIndexedDBLockRefusesAndLocalStorageLockIsReleased() throws {
        let p = try make()
        let before = try ClaudeStoreFixture.snapshot(p.path)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,time\nf=open(sys.argv[1],'a+')\nfcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nprint('ok',flush=True)\ntime.sleep(30)", ClaudeStoreFixture.idbFolder(p).appendingPathComponent("LOCK").path]
        let out = Pipe(); child.standardOutput = out
        try child.run()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        expectRefusal("store is locked") { try ClaudePinStore.write(["local_z"], to: p, backups: self.backups, now: self.now) }
        XCTAssertEqual(try ClaudeStoreFixture.snapshot(p.path), before)
        child.terminate(); child.waitUntilExit()
        XCTAssertTrue(try ClaudePinStore.write(["local_z"], to: p, backups: backups, now: now))
    }
}
