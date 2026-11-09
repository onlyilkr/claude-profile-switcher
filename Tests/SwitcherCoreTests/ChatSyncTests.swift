import XCTest
@testable import SwitcherCore

final class ChatSyncTests: XCTestCase {
    private var home: URL!
    private var transfer: ChatTransfer!
    private var source: Profile!
    private var target: Profile!
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("chat-sync-\(UUID().uuidString)", isDirectory: true)
        transfer = ChatTransfer(transcriptsRoot: home.appendingPathComponent("projects", isDirectory: true))
        source = Profile(id: "S", name: "Source", path: home.appendingPathComponent("source", isDirectory: true))
        target = Profile(id: "T", name: "Target", path: home.appendingPathComponent("target", isDirectory: true))
        trashed = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    // MARK: fixtures

    private func org(_ p: Profile, _ name: String = "org") throws -> URL {
        let d = ChatTransfer.sessionRoot(p).appendingPathComponent("acct-\(p.id)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    private func record(_ p: Profile, _ id: String = "a", cli: String, cwd: String = "/w/app", prior: [String]? = nil,
                        archived: Bool = false, title: String = "Chat", activity: Double = 1_000, modified: Date,
                        extra: [String: Any] = [:]) throws -> URL {
        var obj: [String: Any] = ["sessionId": "local_\(id)", "cliSessionId": cli, "cwd": cwd, "title": title,
                                  "isArchived": archived, "lastActivityAt": activity * 1000]
        if let prior { obj["priorCliSessionIds"] = prior }
        for (k, v) in extra { obj[k] = v }
        let url = try org(p).appendingPathComponent("local_\(id).json")
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func transcript(cli: String, cwd: String = "/w/app", _ messages: [(String, String)]) throws {
        let url = TranscriptLocator.transcript(root: transfer.transcriptsRoot, cwd: cwd, cliSessionID: cli)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = messages.map { "{\"type\":\"user\",\"uuid\":\"\($0.0)\",\"sessionId\":\"\(cli)\",\"timestamp\":\"\($0.1)\"}\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func deletedMarker(_ p: Profile, _ id: String = "a", at ms: String) throws {
        try Data(ms.utf8).write(to: try org(p).appendingPathComponent("deleted_\(id)"))
    }

    private func obj(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func backups(_ p: Profile) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: ChatTransfer.sessionRoot(p).path)) ?? []).filter { $0.contains("switcher-backup") }
    }

    private let older = Date(timeIntervalSince1970: 1_000_000)
    private let newer = Date(timeIntervalSince1970: 2_000_000)

    private func plan() -> ChatSyncPlan { ChatSync.plan(target: target, source: source, transfer: transfer) }

    @discardableResult
    private func apply(_ plan: ChatSyncPlan, open: [URL] = []) throws -> ChatSyncReport {
        try ChatSync.apply(plan, to: target, openFolders: open, trash: { [unowned self] url in
            self.trashed.append(url)
            try FileManager.default.removeItem(at: url)
        })
    }

    /// The target is on the old history; the source resumed the chat under a new one that continues it.
    private func resumedInSource(oldExtra: [String] = []) throws -> URL {
        let t = try record(target, cli: "old", modified: older,
                           extra: ["bridgeSessionIds": ["target-bridge"], "isStarred": true, "remoteMcpServersConfig": ["target"]])
        try record(source, cli: "new", prior: ["older", "old"], title: "Renamed", activity: 2_000, modified: newer,
                   extra: ["bridgeSessionIds": ["source-bridge"], "isStarred": false, "remoteMcpServersConfig": ["source"],
                           "lastAssistantUuid": "n1"])
        try transcript(cli: "old", [("u1", "2025-01-01T10:00:00.000Z")] + oldExtra.map { ($0, "2025-01-03T10:00:00.000Z") })
        try transcript(cli: "new", [("u1", "2025-01-01T10:00:00.000Z"), ("n1", "2025-01-02T10:00:00.000Z")])
        return t
    }

    // MARK: history

    func testABehindCopyFollowsItsContinuationAndKeepsItsAccountFields() throws {
        let t = try resumedInSource()
        let report = try apply(plan())
        XCTAssertEqual(report.histories, 1)
        let r = try obj(t)
        XCTAssertEqual(r["cliSessionId"] as? String, "new")
        XCTAssertEqual(r["priorCliSessionIds"] as? [String], ["older", "old"])
        XCTAssertEqual(r["lastAssistantUuid"] as? String, "n1")
        XCTAssertEqual(r["title"] as? String, "Renamed")
        // Account-bound fields, and the pin mirror (pin sync owns it), stay the target's.
        XCTAssertEqual(r["bridgeSessionIds"] as? [String], ["target-bridge"])
        XCTAssertEqual(r["remoteMcpServersConfig"] as? [String], ["target"])
        XCTAssertEqual(r["isStarred"] as? Bool, true)
        XCTAssertEqual(backups(target).count, 1)
        // History files are shared by every account and never touched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: TranscriptLocator.transcript(root: transfer.transcriptsRoot, cwd: "/w/app", cliSessionID: "old").path))
    }

    func testAForkedHistoryIsLeftAloneAndCounted() throws {
        let t = try resumedInSource(oldExtra: ["late"])
        let p = plan()
        XCTAssertEqual(p.forked, 1)
        let report = try apply(p)
        XCTAssertEqual(report.histories, 0)
        XCTAssertEqual(try obj(t)["cliSessionId"] as? String, "old")
    }

    func testACopyInAnotherFolderIsLeftToLinking() throws {
        let t = try record(target, cli: "old", cwd: "/w/wt-1", modified: older)
        try record(source, cli: "new", cwd: "/w/wt-2", prior: ["old"], modified: newer)
        try transcript(cli: "old", cwd: "/w/wt-1", [("u1", "2025-01-01T10:00:00.000Z")])
        try transcript(cli: "new", cwd: "/w/wt-2", [("u1", "2025-01-01T10:00:00.000Z"), ("n1", "2025-01-02T10:00:00.000Z")])
        let p = plan()
        XCTAssertTrue(p.isEmpty)
        try apply(p)
        XCTAssertEqual(try obj(t)["cliSessionId"] as? String, "old")
    }

    func testATargetAheadOfTheSourceIsNotTurnedBack() throws {
        let t = try record(target, cli: "new", prior: ["old"], modified: older)
        try record(source, cli: "old", modified: newer)
        try transcript(cli: "old", [("u1", "2025-01-01T10:00:00.000Z")])
        try transcript(cli: "new", [("u1", "2025-01-01T10:00:00.000Z"), ("n1", "2025-01-02T10:00:00.000Z")])
        try apply(plan())
        XCTAssertEqual(try obj(t)["cliSessionId"] as? String, "new")
    }

    // MARK: archive and title

    /// What an account had for chat "a" when it last synced, at `at` (seconds).
    private func seen(_ p: Profile, archived: Bool? = nil, title: String? = nil, at: Double = 100) -> ChatSync.Baseline {
        [p.id: ["local_a": .init(archived: archived.map { .init(value: $0 ? "1" : "0", at: at) },
                                 title: title.map { .init(value: ChatSync.titleKey($0), at: at) })]]
    }

    private func planWith(_ parts: ChatSync.Baseline...) -> ChatSyncPlan {
        let baseline = parts.reduce(into: ChatSync.Baseline()) { all, part in all.merge(part) { $0.merging($1) { $1 } } }
        return ChatSync.plan(target: target, source: source, transfer: transfer, baseline: baseline, now: Date(timeIntervalSince1970: 500))
    }

    func testBeforeAnySyncArchivingWinsWhicheverSideDidIt() throws {
        let t = try record(target, cli: "same", archived: false, modified: newer)
        try record(source, cli: "same", archived: true, modified: older)
        let report = try apply(plan())
        XCTAssertEqual(report.archived, 1)
        XCTAssertEqual(try obj(t)["isArchived"] as? Bool, true)
        XCTAssertEqual(backups(target).count, 1)
    }

    func testBeforeAnySyncAnArchivedTargetStaysArchived() throws {
        let t = try record(target, cli: "same", archived: true, modified: older)
        try record(source, cli: "same", archived: false, modified: newer)
        XCTAssertTrue(plan().isEmpty)
        XCTAssertEqual(try obj(t)["isArchived"] as? Bool, true)
    }

    func testBeforeAnySyncACopyUsedAfterTheOtherWasArchivedStaysInUse() throws {
        let t = try record(target, cli: "same", archived: false, activity: 3_000, modified: older)
        try record(source, cli: "same", archived: true, activity: 1_000, modified: newer)
        XCTAssertTrue(plan().isEmpty)
        XCTAssertEqual(try obj(t)["isArchived"] as? Bool, false)
        // The other way round: the source's copy is the one in use, so the target's is unarchived.
        try record(target, cli: "same", archived: true, activity: 1_000, modified: older)
        try record(source, cli: "same", archived: false, activity: 3_000, modified: newer)
        XCTAssertEqual(try apply(plan()).unarchived, 1)
        XCTAssertEqual(try obj(t)["isArchived"] as? Bool, false)
    }

    func testAnUnarchiveDoneOnlyInTheSourceFollows() throws {
        let t = try record(target, cli: "same", archived: true, modified: newer)
        try record(source, cli: "same", archived: false, modified: older)
        let report = try apply(planWith(seen(target, archived: true), seen(source, archived: true)))
        XCTAssertEqual(report.unarchived, 1)
        XCTAssertEqual(try obj(t)["isArchived"] as? Bool, false)
    }

    func testAChangeMadeOnlyHereIsKept() throws {
        let t = try record(target, cli: "same", archived: true, title: "Mine", modified: older)
        try record(source, cli: "same", archived: false, title: "Agreed", modified: newer)
        let p = planWith(seen(target, archived: false, title: "Agreed"), seen(source, archived: false, title: "Agreed"))
        XCTAssertTrue(p.isEmpty)
        // The source did not take the target's change: what it last synced stays, so it picks the change up later.
        XCTAssertNil(p.seen[source.id]?["local_a"]?.archived)
        XCTAssertNil(p.seen[source.id]?["local_a"]?.title)
        XCTAssertEqual(p.seen[target.id]?["local_a"]?.archived, .init(value: "1", at: 500))
        try apply(p)
        XCTAssertEqual(try obj(t)["isArchived"] as? Bool, true)
        XCTAssertEqual(try obj(t)["title"] as? String, "Mine")
    }

    func testWhenBothRenamedTheSourceWins() throws {
        let t = try record(target, cli: "same", title: "Mine", modified: newer)
        try record(source, cli: "same", title: "Theirs", modified: older, extra: ["titleSource": "user"])
        let report = try apply(planWith(seen(target, title: "Agreed"), seen(source, title: "Agreed")))
        XCTAssertEqual(report.renamed, 1)
        XCTAssertEqual(try obj(t)["title"] as? String, "Theirs")
        XCTAssertEqual(try obj(t)["titleSource"] as? String, "user")
    }

    func testBeforeAnySyncAUserTitleBeatsAnAutomaticOne() throws {
        let t = try record(target, cli: "same", title: "Named by me", modified: older, extra: ["titleSource": "user"])
        try record(source, cli: "same", title: "Auto", modified: newer, extra: ["titleSource": "auto"])
        XCTAssertTrue(plan().isEmpty)
        XCTAssertEqual(try obj(t)["title"] as? String, "Named by me")
        try record(target, cli: "same", title: "Auto here", modified: older, extra: ["titleSource": "auto"])
        try record(source, cli: "same", title: "Named there", modified: newer, extra: ["titleSource": "user"])
        try apply(plan())
        XCTAssertEqual(try obj(t)["title"] as? String, "Named there")
    }

    /// Three accounts: a rename in one reached another, while a third kept the old title. Neither the account
    /// with the new title nor the stale one changed anything since its own last sync, so the newer agreement wins,
    /// whichever account is opened.
    func testAStaleAccountDoesNotUndoAChangeMadeElsewhere() throws {
        // The target has the new title and archived it, both agreed at 200; the source last synced at 100.
        let t = try record(target, cli: "same", archived: true, title: "New", modified: older)
        try record(source, cli: "same", archived: false, title: "Old", modified: newer)
        let p = planWith(seen(target, archived: true, title: "New", at: 200), seen(source, archived: false, title: "Old", at: 100))
        XCTAssertTrue(p.isEmpty)
        try apply(p)
        XCTAssertEqual(try obj(t)["title"] as? String, "New")
        XCTAssertEqual(try obj(t)["isArchived"] as? Bool, true)
        // The stale account opened from the up-to-date one takes the change.
        let u = try record(target, cli: "same", archived: false, title: "Old", modified: older)
        try record(source, cli: "same", archived: true, title: "New", modified: newer)
        let report = try apply(planWith(seen(target, archived: false, title: "Old", at: 100), seen(source, archived: true, title: "New", at: 200)))
        XCTAssertEqual(report.archived, 1)
        XCTAssertEqual(try obj(u)["title"] as? String, "New")
    }

    func testTheRunRecordsWhatEachAccountNowHas() throws {
        try record(target, cli: "same", archived: false, title: "Same", modified: older)
        try record(source, cli: "same", archived: true, title: "Same", modified: newer)
        let p = ChatSync.plan(target: target, source: source, transfer: transfer, now: Date(timeIntervalSince1970: 500))
        let now = ChatSync.Seen(archived: .init(value: "1", at: 500), title: .init(value: ChatSync.titleKey("Same"), at: 500))
        XCTAssertEqual(p.seen[target.id]?["local_a"], now)
        XCTAssertEqual(p.seen[source.id]?["local_a"], now)
    }

    // MARK: deletion

    /// Both accounts had the chat at an earlier sync.
    private var bothHadIt: [ChatSync.Baseline] { [seen(target, archived: false), seen(source, archived: false)] }

    private func planBothHadIt() -> ChatSyncPlan { planWith(bothHadIt[0], bothHadIt[1]) }

    func testADeletionFollowsLikeClaudeDoesIt() throws {
        let t = try record(target, cli: "same", activity: 1_000, modified: older)
        try deletedMarker(source, at: "1500000")
        let report = try apply(planBothHadIt())
        XCTAssertEqual(report.deleted, 1)
        XCTAssertEqual(trashed.map(\.lastPathComponent), [t.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path))
        let marker = try org(target).appendingPathComponent("deleted_a")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "1500000")
    }

    func testAMarkerNamedWithTheLocalPrefixCountsToo() throws {
        let t = try record(target, cli: "same", activity: 1_000, modified: older)
        try Data("1500000".utf8).write(to: try org(source).appendingPathComponent("deleted_local_a"))
        XCTAssertEqual(try apply(planBothHadIt()).deleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path))
    }

    /// The transfer keeps lastActivityAt, so "copied here, then the original deleted there" (a move) looks just
    /// like "deleted there, unused here". A chat both accounts never had at a sync is not deleted.
    func testAMovedChatIsNotDeletedWhenTheOriginalIs() throws {
        let t = try record(target, cli: "same", activity: 1_000, modified: older)
        try deletedMarker(source, at: "1500000")
        for p in [plan(), planWith(seen(target, archived: false))] {
            XCTAssertTrue(p.isEmpty)
            XCTAssertEqual(p.keptAfterDeletion, 0, "not a deletion to report either")
        }
        try apply(plan())
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.path))
        XCTAssertTrue(trashed.isEmpty)
    }

    func testAChatUsedHereAfterItWasDeletedThereIsKept() throws {
        let t = try record(target, cli: "same", activity: 2_000, modified: newer)
        try deletedMarker(source, at: "1500000")
        let p = planBothHadIt()
        XCTAssertEqual(p.keptAfterDeletion, 1)
        try apply(p)
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.path))
        XCTAssertTrue(trashed.isEmpty)
    }

    func testAnUnreadableDeletionTimeDeletesNothing() throws {
        let t = try record(target, cli: "same", modified: older)
        try deletedMarker(source, at: "")
        try apply(planBothHadIt())
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.path))
    }

    // MARK: safety

    func testNothingIsWrittenWhileTheTargetIsOpen() throws {
        let t = try resumedInSource()
        XCTAssertThrowsError(try apply(plan(), open: [target.path]))
        XCTAssertEqual(try obj(t)["cliSessionId"] as? String, "old")
        XCTAssertTrue(backups(target).isEmpty)
    }

    func testARecordChangedSincePlanningIsSkipped() throws {
        let t = try resumedInSource()
        let p = plan()
        try record(target, cli: "old", title: "Changed meanwhile", modified: older)
        let report = try apply(p)
        XCTAssertEqual(report.histories, 0)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(try obj(t)["title"] as? String, "Changed meanwhile")
    }

    func testAChatOnlyInTheSourceIsNotCopied() throws {
        try record(source, "only-there", cli: "x", modified: newer)
        XCTAssertTrue(plan().isEmpty)
    }
    // MARK: launch path

    final class Lines { var info: [String] = []; var errors: [String] = []; var notes: [String: String?] = [:] }

    @discardableResult
    private func launchSync(open: [URL] = [], lines: Lines = Lines(), state: ChatSyncState? = nil,
                            relation: @escaping (URL, URL) throws -> TranscriptRelation = TranscriptDiff.compareContinuation) -> Lines {
        let now = Date()
        Switcher.syncChatsBeforeLaunch(target: target, among: [source, target], openFolders: { open }, transfer: transfer, state: state,
                                       lastUsed: { [unowned self] in $0.id == self.source.id ? now : now.addingTimeInterval(-3600) },
                                       relation: relation, trash: { try FileManager.default.removeItem(at: $0) },
                                       note: { lines.notes[$0] = $1 }, log: { lines.info.append($0) }, logError: { lines.errors.append($0) })
        return lines
    }

    func testLaunchSyncsChatsAndLogsOnlyCounts() throws {
        let t = try resumedInSource()
        let lines = launchSync()
        XCTAssertEqual(try obj(t)["cliSessionId"] as? String, "new")
        XCTAssertEqual(lines.info, ["Chats synced from 'Source' to 'Target' (1 history, 0 archived, 0 unarchived, 0 renamed, 0 deleted)"])
        XCTAssertTrue(lines.errors.isEmpty)
        XCTAssertEqual(lines.notes.count, 1)
        XCTAssertEqual(lines.notes.first?.key, target.id)
        XCTAssertNil(lines.notes.first?.value ?? nil, "nothing to report clears the note")
    }

    /// The end-to-end path of a deletion: a sync while both have the chat, then a deletion there.
    func testADeletionFollowsOnceBothHadTheChatAtASync() throws {
        let state = ChatSyncState(file: home.appendingPathComponent("state.json"))
        let t = try record(target, cli: "same", activity: 1_000, modified: older)
        let s = try record(source, cli: "same", activity: 1_000, modified: older)
        launchSync(state: state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.path))
        try FileManager.default.removeItem(at: s)
        try deletedMarker(source, at: String(Int(Date().timeIntervalSince1970 * 1000)))
        let lines = launchSync(state: ChatSyncState(file: home.appendingPathComponent("state.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path))
        XCTAssertTrue(lines.info.first?.hasSuffix("1 deleted)") == true, lines.info.joined())
    }

    func testLaunchLeavesAnOpenTargetAlone() throws {
        let t = try resumedInSource()
        let lines = launchSync(open: [target.path])
        XCTAssertEqual(try obj(t)["cliSessionId"] as? String, "old")
        XCTAssertTrue(lines.info.isEmpty)
    }

    func testAnAccountOpenedWhilePlanningIsNotWritten() throws {
        let t = try resumedInSource()
        var calls = 0
        Switcher.syncChatsBeforeLaunch(target: target, among: [source, target], openFolders: { [unowned self] in
            calls += 1
            return calls > 1 ? [self.target.path] : []
        }, transfer: transfer, lastUsed: { [unowned self] in $0.id == self.source.id ? Date() : Date(timeIntervalSince1970: 0) },
           note: { _, _ in }, log: { _ in }, logError: { _ in })
        XCTAssertGreaterThan(calls, 1, "checked again right before writing")
        XCTAssertEqual(try obj(t)["cliSessionId"] as? String, "old")
    }

    func testLaunchNotesForkedChatsWithoutNamingThem() throws {
        try resumedInSource(oldExtra: ["late"])
        let lines = launchSync()
        let note = try XCTUnwrap(lines.notes[target.id] ?? nil)
        XCTAssertTrue(note.contains("1"), note)
        XCTAssertFalse(note.contains("Chat"), "no chat titles in the note")
    }

    func testLaunchWithoutASourceDoesNothingAndClearsTheNote() throws {
        let t = try resumedInSource()
        let lines = Lines()
        Switcher.syncChatsBeforeLaunch(target: target, among: [source, target], openFolders: { [] }, transfer: transfer,
                                       lastUsed: { [unowned self] in $0.id == self.target.id ? Date() : nil },
                                       note: { lines.notes[$0] = $1 }, log: { lines.info.append($0) }, logError: { lines.errors.append($0) })
        XCTAssertEqual(try obj(t)["cliSessionId"] as? String, "old")
        XCTAssertEqual(lines.notes.count, 1)
        XCTAssertNil(lines.notes[target.id] ?? nil)
    }

    func testChatNotesReachThePanelNextToPinNotes() {
        let profiles = [target!, source!]
        let notes = Switcher.panelNotes(profiles: profiles, pin: [target.id: "Pins.", "gone": "x"], chat: [target.id: "Chats.", source.id: "Only chats."],
                                        restore: [:])
        XCTAssertEqual(notes, [target.id: "Pins. Chats.", source.id: "Only chats."])
    }

    func testRelationCacheReadsAPairOnceUntilAFileChanges() throws {
        try resumedInSource(oldExtra: ["late"])
        let cache = RelationCache(file: home.appendingPathComponent("cache.json"))
        var runs = 0
        let counting: (URL, URL) throws -> TranscriptRelation = { runs += 1; return try TranscriptDiff.compareContinuation(older: $0, newer: $1) }
        launchSync(relation: cache.wrap(counting)); cache.save()
        let again = RelationCache(file: home.appendingPathComponent("cache.json"))
        launchSync(relation: again.wrap(counting)); again.save()
        XCTAssertEqual(runs, 1)
        try transcript(cli: "old", [("u1", "2025-01-01T10:00:00.000Z"), ("late", "2025-01-03T10:00:00.000Z"), ("later", "2025-01-04T10:00:00.000Z")])
        let third = RelationCache(file: home.appendingPathComponent("cache.json"))
        launchSync(relation: third.wrap(counting))
        XCTAssertEqual(runs, 2)
    }

    func testRelationCacheKeepsOtherPairsThatStillMatch() throws {
        try resumedInSource(oldExtra: ["late"])
        let file = home.appendingPathComponent("cache.json")
        let first = RelationCache(file: file)
        launchSync(relation: first.wrap(TranscriptDiff.compareContinuation)); first.save()
        // A run that compares nothing (another pair of accounts) keeps the entry.
        let other = RelationCache(file: file)
        other.save()
        var runs = 0
        let again = RelationCache(file: file)
        launchSync(relation: again.wrap { runs += 1; return try TranscriptDiff.compareContinuation(older: $0, newer: $1) })
        XCTAssertEqual(runs, 0)
    }

    func testLaunchRemembersWhatEachAccountHadSoALaterUnarchiveFollows() throws {
        let file = home.appendingPathComponent("state.json")
        let t = try record(target, cli: "same", archived: false, modified: older)
        try record(source, cli: "same", archived: true, modified: newer)
        launchSync(state: ChatSyncState(file: file))
        XCTAssertEqual(try obj(t)["isArchived"] as? Bool, true)
        XCTAssertEqual(ChatSyncState(file: file).baseline[target.id]?["local_a"]?.archived?.value, "1")
        XCTAssertEqual(ChatSyncState(file: file).baseline[source.id]?["local_a"]?.archived?.value, "1")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Chat"), "no titles in the state file")
        // Later the source unarchives it: with what each had known, that follows (archived no longer wins).
        try record(source, cli: "same", archived: false, modified: newer)
        launchSync(state: ChatSyncState(file: file))
        XCTAssertEqual(try obj(t)["isArchived"] as? Bool, false)
    }

    func testTheStateForgetsChatsTheTargetNoLongerHas() throws {
        let file = home.appendingPathComponent("state.json")
        let state = ChatSyncState(file: file)
        state.baseline = [target.id: ["local_gone": .init(archived: .init(value: "0", at: 1), title: nil)],
                          source.id: ["local_gone": .init(archived: .init(value: "0", at: 1), title: nil)]]
        try record(target, cli: "same", modified: older)
        try record(source, cli: "same", modified: newer)
        launchSync(state: state)
        let saved = ChatSyncState(file: file).baseline
        XCTAssertNil(saved[target.id]?["local_gone"])
        XCTAssertNotNil(saved[source.id]?["local_gone"], "the source's own chats are pruned when it is the target")
        XCTAssertNotNil(saved[target.id]?["local_a"])
    }
}
