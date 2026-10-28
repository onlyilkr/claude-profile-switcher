import XCTest
@testable import SwitcherCore

final class LinkPolicyTests: XCTestCase {
    private func copy(_ id: String, lease: Bool? = nil) -> ChatCopy {
        ChatCopy(profileID: id, profileName: id, record: URL(fileURLWithPath: "/r/\(id)"), cwd: "/w", worktreePath: "/w",
                 transcript: URL(fileURLWithPath: "/t/\(id)"), hasTranscript: true, isArchived: false,
                 lastActivity: Date(), leaseHeld: lease)
    }

    private func chat(_ copies: [ChatCopy], _ status: [String: CopyStatus], linked: Bool = false, cli: String = "cli1") -> SharedChat {
        SharedChat(id: "local_x", cliSessionID: cli, title: "T", folder: "f", copies: copies, status: status, isLinked: linked)
    }

    func testVersions() {
        XCTAssertEqual(LinkPolicy.shortVersion("4.29.0"), "4.29")
        XCTAssertEqual(LinkPolicy.shortVersion("4"), "4")
        XCTAssertTrue(LinkPolicy.isTested("4.29.7"))
        XCTAssertFalse(LinkPolicy.isTested("4.30.0"))
    }

    func testWinnerPrefersLeaseHolderAmongLatest() {
        let c = chat([copy("A"), copy("B", lease: true), copy("C")], ["A": .latest, "B": .latest, "C": .willSplit])
        XCTAssertEqual(LinkPolicy.winner(of: c), "B")
        let d = chat([copy("A"), copy("B")], ["A": .behind(messages: 2), "B": .latest])
        XCTAssertEqual(LinkPolicy.winner(of: d), "B")
    }

    func testWinnerFallsBackToWillSplit() {
        let c = chat([copy("A"), copy("B")], ["A": .willSplit, "B": .willSplit])
        XCTAssertEqual(LinkPolicy.winner(of: c), "A")
        XCTAssertNil(LinkPolicy.winner(of: chat([copy("A")], ["A": .noTranscript])))
    }

    func testRowKinds() {
        let forked = chat([copy("A"), copy("B"), copy("C")], ["A": .latest, "B": .forked(messages: 3), "C": .behind(messages: 1)])
        XCTAssertTrue(LinkPolicy.isForked(forked)); XCTAssertTrue(LinkPolicy.isBehind(forked))
        XCTAssertEqual(LinkPolicy.forkChoices(forked).map(\.profileID), ["A", "B"])
        XCTAssertTrue(LinkPolicy.needsLinking(chat([copy("A")], ["A": .willSplit])))
    }

    func testOpenInSeveralNeedsLinkedChatAndTwoFolders() {
        let linked = chat([copy("A")], ["A": .latest], linked: true)
        let plain = chat([copy("A")], ["A": .latest], linked: false)
        let live: [(pid: pid_t, profileDir: String, cliSessionID: String)] = [(1, "/p/a", "cli1"), (2, "/p/b/", "cli1"), (3, "/p/a", "other")]
        XCTAssertEqual(LinkPolicy.openInSeveral([linked, plain], live: live).count, 1)
        XCTAssertTrue(LinkPolicy.openInSeveral([linked], live: [(1, "/p/a", "cli1"), (2, "/p/a", "cli1")]).isEmpty)
    }

    func testHasBrokenOnlyForLinkedChats() {
        XCTAssertTrue(LinkPolicy.hasBroken([chat([copy("A")], ["A": .linkBroken], linked: true)]))
        XCTAssertFalse(LinkPolicy.hasBroken([chat([copy("A")], ["A": .linkBroken], linked: false)]))
    }

    func testLinkAllOnlyPlainSplits() {
        XCTAssertTrue(LinkPolicy.isPlainSplit(chat([copy("A"), copy("B")], ["A": .latest, "B": .willSplit])))
        XCTAssertFalse(LinkPolicy.isPlainSplit(chat([copy("A"), copy("B"), copy("C")], ["A": .latest, "B": .willSplit, "C": .behind(messages: 1)])))
        XCTAssertFalse(LinkPolicy.isPlainSplit(chat([copy("A"), copy("B")], ["A": .latest, "B": .archivedHereOnly])))
        XCTAssertEqual(LinkPolicy.brokenIDs([chat([copy("A")], ["A": .linkBroken], linked: true)]), ["local_x"])
    }
}
