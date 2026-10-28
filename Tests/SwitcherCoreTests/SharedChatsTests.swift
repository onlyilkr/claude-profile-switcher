import XCTest
@testable import SwitcherCore

final class SharedChatsTests: XCTestCase {
    func testProjectDirNameMatchesClaude() {
        XCTAssertEqual(
            TranscriptLocator.projectDirName(for: "/Users/ilkerguldali/workspace/halal-backend/.claude/worktrees/sharp-liskov-9f53ee"),
            "-Users-ilkerguldali-workspace-halal-backend--claude-worktrees-sharp-liskov-9f53ee")
        // Every non-alphanumeric UTF-16 unit becomes "-" (after NFC), so letters like Ğ, ü, ş and the space are replaced.
        XCTAssertEqual(TranscriptLocator.projectDirName(for: "/Users/a/Proje Ğüş"), "-Users-a-Proje----")
        // A character outside the BMP is two UTF-16 units, so it gives two dashes.
        XCTAssertEqual(TranscriptLocator.projectDirName(for: "/a/😀"), "-a---")
        // Decomposed input is normalised first: "e" + combining acute is one unit after NFC.
        XCTAssertEqual(TranscriptLocator.projectDirName(for: "/a/e\u{301}"), "-a--")
    }

    func testLongNamesGetHashSuffix() {
        // Constant computed once outside Swift (32-bit wrapping hash over the UTF-16 units of the raw, unencoded path, base 36).
        let expected = String(repeating: "-", count: 1) + String(repeating: "x", count: 199) + "-v734pd"
        XCTAssertEqual(TranscriptLocator.projectDirName(for: "/" + String(repeating: "x", count: 250)), expected)
        // Exactly 200 characters stays untouched.
        let exact = "/" + String(repeating: "x", count: 199)
        XCTAssertEqual(TranscriptLocator.projectDirName(for: exact), "-" + String(repeating: "x", count: 199))
    }

    func testTranscriptAndSidecarPaths() {
        let root = URL(fileURLWithPath: "/tmp/claude-projects")
        let t = TranscriptLocator.transcript(root: root, cwd: "/a/b", cliSessionID: "sid-1")
        XCTAssertEqual(t.path, "/tmp/claude-projects/-a-b/sid-1.jsonl")
        let s = TranscriptLocator.sidecar(root: root, cwd: "/a/b", cliSessionID: "sid-1")
        XCTAssertEqual(s.path, "/tmp/claude-projects/-a-b/sid-1")
    }
}

final class TranscriptDiffTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ lines: [String], trailing: String = "") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let text = lines.map { $0 + "\n" }.joined() + trailing
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func msg(_ i: Int) -> String { "{\"type\":\"user\",\"uuid\":\"u\(i)\",\"text\":\"hello \(i)\"}" }
    private var common: [String] { (1...3).map(msg) }

    func testIdenticalFiles() throws {
        let a = try write("a.jsonl", common), b = try write("b.jsonl", common)
        XCTAssertEqual(try TranscriptDiff.compare(a, b), .identical)
    }

    func testMetadataOnlyTailIsInSync() throws {
        let a = try write("a.jsonl", common)
        let b = try write("b.jsonl", common + ["{\"type\":\"cost-state\"}"])
        XCTAssertEqual(try TranscriptDiff.compare(a, b), .identical)
    }

    func testBehindLikeTheRealCase() throws {
        let q = "{\"type\":\"queue-operation\",\"op\":\"enqueue\"}"
        let a = try write("a.jsonl", common + [q, q] + (4...7).map(msg))
        let b = try write("b.jsonl", common + ["{\"type\":\"cost-state\",\"n\":1}", "{\"type\":\"cost-state\",\"n\":2}"])
        XCTAssertEqual(try TranscriptDiff.compare(a, b), .firstAhead(messages: 4))
        XCTAssertEqual(try TranscriptDiff.compare(b, a), .secondAhead(messages: 4))
    }

    func testForked() throws {
        let a = try write("a.jsonl", common + [msg(10), msg(11)])
        let b = try write("b.jsonl", common + [msg(20)])
        XCTAssertEqual(try TranscriptDiff.compare(a, b), .forked(first: 2, second: 1))
    }

    func testPartialLastLineIsIgnored() throws {
        let a = try write("a.jsonl", common)
        let b = try write("b.jsonl", common, trailing: "{\"uuid\":\"x\"")
        XCTAssertEqual(try TranscriptDiff.compare(a, b), .identical)
    }

    func testCorruptLineCountsAsMeta() throws {
        XCTAssertFalse(TranscriptDiff.isMessageLine(Data("not json".utf8)))
        XCTAssertFalse(TranscriptDiff.isMessageLine(Data("[1,2]".utf8)))
        XCTAssertFalse(TranscriptDiff.isMessageLine(Data("{\"uuid\":5}".utf8)))
        XCTAssertTrue(TranscriptDiff.isMessageLine(Data("{\"uuid\":\"x\"}".utf8)))
        let a = try write("a.jsonl", common)
        let b = try write("b.jsonl", common + ["not json"])
        XCTAssertEqual(try TranscriptDiff.compare(a, b), .identical)
    }

    func testCompareStreamsLargeFiles() throws {
        let line = "{\"type\":\"user\",\"uuid\":\"" + String(repeating: "a", count: 990) + "\"}\n"
        let chunk = Data(String(repeating: line, count: 1000).utf8)   // ~1 MB
        func build(_ name: String, tail: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            for _ in 0..<39 { h.write(chunk) }
            h.write(Data(tail.utf8))
            try h.close()
            return url
        }
        let a = try build("big-a.jsonl", tail: String(repeating: line, count: 1000))
        let b = try build("big-b.jsonl", tail: String(repeating: "{\"type\":\"cost-state\"}\n", count: 10))
        let start = Date()
        let rel = try TranscriptDiff.compare(a, b)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(rel, .firstAhead(messages: 1000))
    }
}

final class WorktreeLeasesTests: XCTestCase {
    private var dir: URL!
    private var profile: Profile!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-leases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        profile = Profile(id: "Work", name: "Work", path: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample(leasedBy: Any = "local_A") -> [String: Any] {
        [
            "schemaVersion": 2,
            "worktrees": [
                "wt-one": [
                    "name": "wt-one", "path": "/r/.claude/worktrees/wt-one", "leasedBy": leasedBy,
                    "baseRepo": "/r", "branch": "claude/wt-one", "sourceBranch": "main", "createdAt": 1_700_000_000_000,
                    "autoTrusted": true, "leaseCleared": true, "pooledAt": 5, "parkedStateKey": "k", "uncleanSince": 7,
                ] as [String: Any],
            ] as [String: Any],
            "untrackedDirGc": ["a": 1], "originUrls": ["u": "x"], "originPins": ["p": "y"],
        ]
    }

    private func writeRaw(_ obj: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: WorktreeLeases.file(profile))
    }

    func testLeasesReadStates() throws {
        XCTAssertEqual(WorktreeLeases.read(profile), .missing)
        try Data("{ nope".utf8).write(to: WorktreeLeases.file(profile))
        XCTAssertEqual(WorktreeLeases.read(profile), .unreadable)
        var v3 = sample(); v3["schemaVersion"] = 3
        try writeRaw(v3)
        XCTAssertEqual(WorktreeLeases.read(profile), .unsupported(schema: 3))
        try writeRaw(["worktrees": [String: Any]()])
        XCTAssertEqual(WorktreeLeases.read(profile), .unsupported(schema: nil))
        try writeRaw(sample())
        guard case .ok(let root) = WorktreeLeases.read(profile) else { return XCTFail("expected ok") }
        XCTAssertEqual(root["schemaVersion"] as? Int, 2)
        XCTAssertEqual(WorktreeLeases.read(profile), .ok(sample()))
    }

    func testHolderMatchesNormalisedPath() {
        let root = sample()
        XCTAssertEqual(WorktreeLeases.holder(of: "/r/.claude/worktrees/wt-one/", in: root), "local_A")
        XCTAssertEqual(WorktreeLeases.holder(of: "/r/.claude/worktrees/../worktrees/wt-one", in: root), "local_A")
        XCTAssertNil(WorktreeLeases.holder(of: "/r/other", in: root))
        XCTAssertNil(WorktreeLeases.holder(of: "/r/.claude/worktrees/wt-one", in: sample(leasedBy: NSNull())))
    }

    func testAddingCopiesEntryAsAdopted() throws {
        let source = sample()
        let entry = try XCTUnwrap(WorktreeLeases.entry(leasedTo: "local_A", path: "/r/.claude/worktrees/wt-one/", in: source))
        XCTAssertEqual(entry.name, "wt-one")
        var target = sample(); target["worktrees"] = [String: Any]()
        let before = NSDictionary(dictionary: target)
        let out = try WorktreeLeases.adding(entry, for: "local_B", to: target)
        XCTAssertTrue(before.isEqual(to: target), "input must not change")
        let wt = try XCTUnwrap((out["worktrees"] as? [String: Any])?["wt-one"] as? [String: Any])
        XCTAssertEqual(wt["leasedBy"] as? String, "local_B")
        XCTAssertEqual(wt["adopted"] as? Bool, true)
        for k in ["leaseCleared", "pooledAt", "parkedStateKey", "uncleanSince"] { XCTAssertNil(wt[k], k) }
        XCTAssertEqual(wt["baseRepo"] as? String, "/r")
        XCTAssertEqual(wt["branch"] as? String, "claude/wt-one")
        XCTAssertEqual(wt["createdAt"] as? Int, 1_700_000_000_000)
        XCTAssertEqual(wt["autoTrusted"] as? Bool, true)
        for k in ["originUrls", "originPins", "untrackedDirGc", "schemaVersion"] {
            XCTAssertTrue(NSDictionary(dictionary: [k: target[k]!]).isEqual(to: [k: out[k]!]), k)
        }
    }

    func testAddingRefusesPathLeasedToAnotherSession() throws {
        let entry = (name: "wt-one", value: try XCTUnwrap((sample()["worktrees"] as? [String: Any])?["wt-one"] as? [String: Any]))
        // Same path, other name.
        var other = sample()
        var wts = try XCTUnwrap(other["worktrees"] as? [String: Any])
        var e = try XCTUnwrap(wts["wt-one"] as? [String: Any]); e["name"] = "wt-two"
        wts = ["wt-two": e]; other["worktrees"] = wts
        XCTAssertThrowsError(try WorktreeLeases.adding(entry, for: "local_B", to: other)) { XCTAssertFalse(($0 as? SwitcherError)?.message.isEmpty ?? true) }
        // Same name, other path.
        var e2 = e; e2["path"] = "/elsewhere"
        other["worktrees"] = ["wt-one": e2]
        XCTAssertThrowsError(try WorktreeLeases.adding(entry, for: "local_B", to: other))
    }

    func testAddingIsNoOpWhenAlreadyLeasedToSameSession() throws {
        let root = sample(leasedBy: "local_B")
        let entry = (name: "wt-one", value: try XCTUnwrap((root["worktrees"] as? [String: Any])?["wt-one"] as? [String: Any]))
        let out = try WorktreeLeases.adding(entry, for: "local_B", to: root)
        XCTAssertTrue(NSDictionary(dictionary: root).isEqual(to: out))
    }

    func testReleasingClearsLease() throws {
        let root = sample()
        let out = WorktreeLeases.releasing(name: "wt-one", from: root)
        let wt = try XCTUnwrap((out["worktrees"] as? [String: Any])?["wt-one"] as? [String: Any])
        XCTAssertTrue(wt["leasedBy"] is NSNull)
        XCTAssertEqual(wt["leaseCleared"] as? Bool, true)
        XCTAssertEqual(wt["branch"] as? String, "claude/wt-one")
        XCTAssertEqual((root["worktrees"] as? [String: Any])?["wt-one"].flatMap { ($0 as? [String: Any])?["leasedBy"] as? String }, "local_A")
        XCTAssertTrue(NSDictionary(dictionary: WorktreeLeases.releasing(name: "nope", from: root)).isEqual(to: root))
    }

    func testLeasesRefuseUnknownSchema() throws {
        var v3 = sample(); v3["schemaVersion"] = 3
        try writeRaw(v3)
        XCTAssertThrowsError(try WorktreeLeases.write(v3, basedOn: v3, to: profile))
        // Root being written is checked too, not only the file on disk.
        try writeRaw(sample())
        XCTAssertThrowsError(try WorktreeLeases.write(v3, basedOn: sample(), to: profile))
        XCTAssertEqual(WorktreeLeases.read(profile), .ok(sample()))
        try Data("{ nope".utf8).write(to: WorktreeLeases.file(profile))
        XCTAssertThrowsError(try WorktreeLeases.write(sample(), basedOn: sample(), to: profile))
    }

    func testLeasesNeverCreateFile() {
        XCTAssertThrowsError(try WorktreeLeases.write(sample(), basedOn: sample(), to: profile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: WorktreeLeases.file(profile).path))
    }

    func testLeasesWriteThroughSymlink() throws {
        let real = dir.appendingPathComponent("shared-real.json")
        try JSONSerialization.data(withJSONObject: sample()).write(to: real)
        try FileManager.default.createSymbolicLink(at: WorktreeLeases.file(profile), withDestinationURL: real)
        let changed = WorktreeLeases.releasing(name: "wt-one", from: sample())
        try WorktreeLeases.write(changed, basedOn: sample(), to: profile)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: WorktreeLeases.file(profile).path))
        guard case .ok(let root) = WorktreeLeases.read(profile) else { return XCTFail("expected ok") }
        XCTAssertTrue(NSDictionary(dictionary: root).isEqual(to: changed))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("shared-real.json.switcher-backup-") }, "\(names)")
        let attrs = try FileManager.default.attributesOfItem(atPath: real.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWriteRefusesWhenFileChangedSinceRead() throws {
        try writeRaw(sample())
        var changedOnDisk = sample(); changedOnDisk["originUrls"] = ["z": "q"]
        try writeRaw(changedOnDisk)
        XCTAssertThrowsError(try WorktreeLeases.write(WorktreeLeases.releasing(name: "wt-one", from: sample()), basedOn: sample(), to: profile))
        XCTAssertEqual(WorktreeLeases.read(profile), .ok(changedOnDisk))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains { $0.contains("switcher-backup") })
    }

    func testAddingReplacesUnleasedEntry() throws {
        var root = sample()
        var old = try XCTUnwrap((root["worktrees"] as? [String: Any])?["wt-one"] as? [String: Any])
        old["leasedBy"] = NSNull(); old["leaseCleared"] = true
        root["worktrees"] = ["old-key": old]
        let entry = (name: "wt-one", value: try XCTUnwrap((sample()["worktrees"] as? [String: Any])?["wt-one"] as? [String: Any]))
        let out = try WorktreeLeases.adding(entry, for: "local_B", to: root)
        let wts = try XCTUnwrap(out["worktrees"] as? [String: Any])
        XCTAssertEqual(Set(wts.keys), ["wt-one"])
        let wt = try XCTUnwrap(wts["wt-one"] as? [String: Any])
        XCTAssertEqual(wt["leasedBy"] as? String, "local_B")
        XCTAssertEqual(wt["adopted"] as? Bool, true)
        XCTAssertNil(wt["leaseCleared"])
    }

    func testAddingRefusesUnexpectedLeaseType() throws {
        let root = sample(leasedBy: 42)
        let entry = (name: "wt-one", value: try XCTUnwrap((sample()["worktrees"] as? [String: Any])?["wt-one"] as? [String: Any]))
        XCTAssertThrowsError(try WorktreeLeases.adding(entry, for: "local_B", to: root))
    }
}

final class SharedChatScannerTests: XCTestCase {
    private var home: URL!
    private var projects: URL!
    private var profileA: Profile!
    private var profileB: Profile!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("shared-chat-scan-\(UUID().uuidString)", isDirectory: true)
        projects = home.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        profileA = try makeProfile("A")
        profileB = try makeProfile("B")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func makeProfile(_ id: String) throws -> Profile {
        let dir = home.appendingPathComponent("profile-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Profile(id: id, name: "Profile \(id)", path: dir)
    }

    private func orgDir(_ p: Profile) throws -> URL {
        let d = ChatTransfer.sessionRoot(p).appendingPathComponent("acct", isDirectory: true).appendingPathComponent("org", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    private func record(_ p: Profile, id: String = "s1", cli: String = "cli1", cwd: String = "/work/app",
                        worktree: String? = nil, archived: Bool = false, extra: [String: Any] = [:]) throws -> URL {
        var obj: [String: Any] = ["sessionId": "local_\(id)", "cliSessionId": cli, "cwd": cwd, "title": "Title",
                                  "isArchived": archived, "lastActivityAt": 1_700_000_000_000]
        if let worktree { obj["worktreePath"] = worktree }
        for (k, v) in extra { obj[k] = v }
        let url = try orgDir(p).appendingPathComponent("local_\(id).json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }

    private func msg(_ i: Int) -> String { "{\"type\":\"user\",\"uuid\":\"u\(i)\"}" }

    private func transcript(cwd: String, cli: String = "cli1", lines: [String]) throws {
        let url = TranscriptLocator.transcript(root: projects, cwd: cwd, cliSessionID: cli)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.map { $0 + "\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
    }

    private func scanner(linked: Set<String> = [], compare: @escaping (URL, URL) throws -> TranscriptRelation = TranscriptDiff.compare) -> SharedChatScanner {
        SharedChatScanner(transcriptsRoot: projects, linkedSessionIDs: { linked }, compare: compare)
    }

    private func writeLeases(_ p: Profile, path: String, leasedBy: String) throws {
        let root: [String: Any] = ["schemaVersion": 2, "worktrees": ["wt": ["name": "wt", "path": path, "leasedBy": leasedBy]]]
        try JSONSerialization.data(withJSONObject: root).write(to: WorktreeLeases.file(p))
    }

    func testScanFindsChatsInTwoProfiles() throws {
        try record(profileA); try record(profileB)
        try record(profileA, id: "only", cli: "c2")
        try transcript(cwd: "/work/app", lines: [msg(1)])
        let chats = scanner().scan([profileA, profileB])
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].id, "local_s1")
        XCTAssertEqual(chats[0].cliSessionID, "cli1")
        XCTAssertEqual(chats[0].title, "Title")
        XCTAssertEqual(chats[0].folder, "app")
        XCTAssertEqual(Set(chats[0].copies.map(\.profileID)), ["A", "B"])
        XCTAssertFalse(chats[0].diverged)
    }

    func testScanMarksBehindCopy() throws {
        try record(profileA, cwd: "/work/a"); try record(profileB, cwd: "/work/b")
        let common = (1...3).map(msg)
        let q = "{\"type\":\"queue-operation\"}"
        try transcript(cwd: "/work/a", lines: common + [q, q] + (4...7).map(msg))
        try transcript(cwd: "/work/b", lines: common + ["{\"type\":\"cost-state\",\"n\":1}", "{\"type\":\"cost-state\",\"n\":2}"])
        let chat = try XCTUnwrap(scanner().scan([profileA, profileB]).first)
        XCTAssertEqual(chat.status["A"], .latest)
        XCTAssertEqual(chat.status["B"], .behind(messages: 4))
        XCTAssertTrue(chat.diverged)
    }

    func testScanMarksForkedAndNoTranscript() throws {
        try record(profileA, cwd: "/work/a"); try record(profileB, cwd: "/work/b")
        try transcript(cwd: "/work/a", lines: [msg(1), msg(10), msg(11)])
        try transcript(cwd: "/work/b", lines: [msg(1), msg(20)])
        var chat = try XCTUnwrap(scanner().scan([profileA, profileB]).first)
        XCTAssertEqual(chat.status["A"], .latest)
        XCTAssertEqual(chat.status["B"], .forked(messages: 1))
        try FileManager.default.removeItem(at: TranscriptLocator.transcript(root: projects, cwd: "/work/b", cliSessionID: "cli1"))
        chat = try XCTUnwrap(scanner().scan([profileA, profileB]).first)
        XCTAssertEqual(chat.status["B"], .noTranscript)
        XCTAssertFalse(chat.copies.first { $0.profileID == "B" }!.hasTranscript)
    }

    func testScanTreatsSameFolderAsInSync() throws {
        try record(profileA); try record(profileB)
        try transcript(cwd: "/work/app", lines: [msg(1), msg(2)])
        let chat = try XCTUnwrap(scanner().scan([profileA, profileB]).first)
        XCTAssertEqual(chat.status, ["A": .latest, "B": .latest])
        XCTAssertFalse(chat.diverged)
    }

    func testScanMarksUnboundWorktreeAsWillSplit() throws {
        try record(profileA, worktree: "/wt/one"); try record(profileB, worktree: "/wt/one")
        try transcript(cwd: "/work/app", lines: [msg(1)])
        try writeLeases(profileA, path: "/wt/one", leasedBy: "local_s1")
        try writeLeases(profileB, path: "/wt/one", leasedBy: "local_other")
        let chat = try XCTUnwrap(scanner().scan([profileA, profileB]).first)
        XCTAssertEqual(chat.status["A"], .latest)
        XCTAssertEqual(chat.status["B"], .willSplit)
        XCTAssertEqual(chat.copies.first { $0.profileID == "A" }?.leaseHeld, true)
        XCTAssertEqual(chat.copies.first { $0.profileID == "B" }?.leaseHeld, false)
        XCTAssertTrue(chat.diverged)
    }

    func testScanSkipsDeletedChats() throws {
        try record(profileA); try record(profileB)
        try transcript(cwd: "/work/app", lines: [msg(1)])
        try Data().write(to: try orgDir(profileB).appendingPathComponent("deleted_local_s1"))
        XCTAssertTrue(scanner().scan([profileA, profileB]).isEmpty)
    }

    func testScanSkipsUnusableRecords() throws {
        for p in [profileA!, profileB!] {
            try record(p, id: "nocli", cli: "")
            try record(p, id: "nocwd", cwd: "")
            try record(p, id: "scratch", cli: "c3", cwd: "/x/scratch-workspaces/y")
            try record(p, id: "remote", cli: "c4", extra: ["backend": ["kind": "remote"]])
            try record(p, id: "localbe", cli: "c5", extra: ["backend": ["kind": "local"]])
        }
        let chats = scanner().scan([profileA, profileB])
        XCTAssertEqual(chats.map(\.id), ["local_localbe"])
    }

    func testScanUsesCacheWhenFilesUnchanged() throws {
        try record(profileA, cwd: "/work/a"); try record(profileB, cwd: "/work/b")
        try transcript(cwd: "/work/a", lines: [msg(1), msg(2)])
        try transcript(cwd: "/work/b", lines: [msg(1)])
        var calls = 0
        let s = scanner(compare: { a, b in calls += 1; return try TranscriptDiff.compare(a, b) })
        let first = s.scan([profileA, profileB])
        XCTAssertGreaterThan(calls, 0)
        let after = calls
        let second = s.scan([profileA, profileB])
        XCTAssertEqual(calls, after)
        XCTAssertEqual(first, second)
    }

    func testScanMarksLinkBrokenWhenLinkedCopiesDiffer() throws {
        try record(profileA, cwd: "/work/a"); try record(profileB, cwd: "/work/b")
        try transcript(cwd: "/work/a", lines: [msg(1)])
        try transcript(cwd: "/work/b", lines: [msg(1)])
        let chat = try XCTUnwrap(scanner(linked: ["local_s1"]).scan([profileA, profileB]).first)
        XCTAssertTrue(chat.isLinked)
        XCTAssertEqual(chat.status["A"], .latest)
        XCTAssertEqual(chat.status["B"], .linkBroken)
        XCTAssertTrue(chat.diverged)
        XCTAssertFalse(try XCTUnwrap(scanner().scan([profileA, profileB]).first).diverged)
    }

    func testScanMarksArchivedHereOnlyWhenLinked() throws {
        try record(profileA, archived: true); try record(profileB)
        try transcript(cwd: "/work/app", lines: [msg(1)])
        let chat = try XCTUnwrap(scanner(linked: ["local_s1"]).scan([profileA, profileB]).first)
        XCTAssertEqual(chat.status["A"], .archivedHereOnly)
        XCTAssertEqual(chat.status["B"], .latest)
        XCTAssertEqual(try XCTUnwrap(scanner().scan([profileA, profileB]).first).status["A"], .latest)
    }

    func testReferenceTakesOverWhenSmallerFileIsAhead() throws {
        try record(profileA, cwd: "/work/a"); try record(profileB, cwd: "/work/b")
        let q = "{\"type\":\"queue-operation\",\"padding\":\"" + String(repeating: "x", count: 200) + "\"}"
        try transcript(cwd: "/work/a", lines: [msg(1)] + Array(repeating: q, count: 10))
        try transcript(cwd: "/work/b", lines: [msg(1), msg(2), msg(3)])
        let chat = try XCTUnwrap(scanner().scan([profileA, profileB]).first)
        XCTAssertEqual(chat.status["B"], .latest)
        XCTAssertEqual(chat.status["A"], .behind(messages: 2))
    }

    func testThreeProfiles() throws {
        let profileC = try makeProfile("C")
        try record(profileA, cwd: "/work/a"); try record(profileB, cwd: "/work/b"); try record(profileC, cwd: "/work/a")
        try transcript(cwd: "/work/a", lines: [msg(1), msg(2), msg(3)])
        try transcript(cwd: "/work/b", lines: [msg(1)])
        let chat = try XCTUnwrap(scanner().scan([profileA, profileB, profileC]).first)
        XCTAssertEqual(chat.status["A"], .latest)
        XCTAssertEqual(chat.status["B"], .behind(messages: 2))
        XCTAssertEqual(chat.status["C"], .latest)
    }

    func testWillSplitOnlyForCopiesSharingAFile() throws {
        try record(profileA, cwd: "/work/a", worktree: "/wt/one"); try record(profileB, cwd: "/work/b", worktree: "/wt/one")
        try transcript(cwd: "/work/a", lines: [msg(1)])
        try transcript(cwd: "/work/b", lines: [msg(1)])
        try writeLeases(profileA, path: "/wt/one", leasedBy: "local_s1")
        try writeLeases(profileB, path: "/wt/one", leasedBy: "local_other")
        let chat = try XCTUnwrap(scanner().scan([profileA, profileB]).first)
        XCTAssertEqual(chat.copies.first { $0.profileID == "B" }?.leaseHeld, false)
        XCTAssertEqual(chat.status["B"], .latest)
    }

    func testLinkBrokenWinsOverBehind() throws {
        try record(profileA, cwd: "/work/a"); try record(profileB, cwd: "/work/b")
        try transcript(cwd: "/work/a", lines: [msg(1), msg(2), msg(3)])
        try transcript(cwd: "/work/b", lines: [msg(1)])
        let chat = try XCTUnwrap(scanner(linked: ["local_s1"]).scan([profileA, profileB]).first)
        XCTAssertEqual(chat.status["A"], .latest)
        XCTAssertEqual(chat.status["B"], .linkBroken)
    }

    func testLeaseUnreadableGivesNilLeaseHeld() throws {
        try record(profileA, worktree: "/wt/one"); try record(profileB, worktree: "/wt/one")
        try transcript(cwd: "/work/app", lines: [msg(1)])
        try Data("not json".utf8).write(to: WorktreeLeases.file(profileA))
        // profile B has no lease file at all
        let chat = try XCTUnwrap(scanner().scan([profileA, profileB]).first)
        XCTAssertTrue(chat.copies.allSatisfy { $0.leaseHeld == nil })
        XCTAssertEqual(chat.status["A"], .latest)
        XCTAssertEqual(chat.status["B"], .latest)
    }

    func testDeletedMarkerWithoutLocalPrefix() throws {
        try record(profileA); try record(profileB)
        try transcript(cwd: "/work/app", lines: [msg(1)])
        try Data().write(to: try orgDir(profileA).appendingPathComponent("deleted_s1.json"))
        XCTAssertTrue(scanner().scan([profileA, profileB]).isEmpty)
    }
}

final class LiveCLISessionTests: XCTestCase {
    private let exe = "/Users/a/Library/Application Support/ClaudeProfile-Account 2/claude-code/2.1.309/x/claude.app/Contents/MacOS/claude"
    private let id = "a4fedaa0-1111-4222-8333-444455556666"

    func testCLISessionFromArgs() {
        let hit = ProcessScanner.cliSession(fromArgs: [exe, "--resume=\(id)"], executable: exe)
        XCTAssertEqual(hit?.cliSessionID, id)
        XCTAssertEqual(hit?.profileDir, "/Users/a/Library/Application Support/ClaudeProfile-Account 2")
        XCTAssertEqual(ProcessScanner.cliSession(fromArgs: [exe, "--verbose", "--resume", id], executable: exe)?.cliSessionID, id)
        // Not Claude's bundled Code binary.
        XCTAssertNil(ProcessScanner.cliSession(fromArgs: ["/usr/local/bin/claude", "--resume=\(id)"], executable: "/usr/local/bin/claude"))
        // No resume argument, or nothing after "--resume".
        XCTAssertNil(ProcessScanner.cliSession(fromArgs: [exe, "--verbose"], executable: exe))
        XCTAssertNil(ProcessScanner.cliSession(fromArgs: [exe, "--resume"], executable: exe))
        XCTAssertNil(ProcessScanner.cliSession(fromArgs: [exe, "--resume="], executable: exe))
    }
}
