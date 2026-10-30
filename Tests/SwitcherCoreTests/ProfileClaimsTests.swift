import XCTest
@testable import SwitcherCore

final class ProfileClaimsTests: XCTestCase {
    private var dir: URL!
    private var file: URL!
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var alive = true

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claims-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("claims.json")
        clock = Date(timeIntervalSince1970: 1_000_000)
        alive = true
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(pid: pid_t = 100) -> ProfileClaims {
        ProfileClaims(file: file, now: { self.clock }, isAlive: { _ in self.alive }, ownPID: pid)
    }

    private func profile(_ id: String) -> Profile {
        Profile(id: id, name: id, path: dir.appendingPathComponent(id))
    }

    func testSecondLaunchWithinTheWindowIsStarting() throws {
        let claims = make()
        XCTAssertEqual(try claims.claimLaunch("Work") { nil }, .go)
        XCTAssertEqual(try claims.claimLaunch("Work") { nil }, .starting)
    }

    func testAProcessThatShowsUpIsFocusedNotRelaunched() throws {
        let claims = make()
        _ = try claims.claimLaunch("Work") { nil }
        XCTAssertEqual(try claims.claimLaunch("Work") { 4242 }, .running(4242))
    }

    func testStartingExpiresAfter20Seconds() throws {
        let claims = make()
        _ = try claims.claimLaunch("Work") { nil }
        clock.addTimeInterval(21)
        XCTAssertFalse(claims.startedRecently("Work"))
        XCTAssertEqual(try claims.claimLaunch("Work") { nil }, .go)
    }

    func testASlowPinSyncKeepsTheClaimFreshThenTheWindowRestarts() throws {
        let claims = make(pid: 100)
        XCTAssertEqual(try claims.claimLaunch("Work") { nil }, .go)
        claims.setSyncing("Work", true)
        clock.addTimeInterval(25)
        XCTAssertEqual(try make(pid: 200).claimLaunch("Work") { nil }, .starting, "still syncing: a second launch must not get through")
        XCTAssertTrue(claims.startedRecently("Work"))
        claims.setSyncing("Work", false)
        clock.addTimeInterval(19)
        XCTAssertEqual(try make(pid: 200).claimLaunch("Work") { nil }, .starting, "the 20 s window runs from the end of the sync")
        clock.addTimeInterval(2)
        XCTAssertEqual(try make(pid: 200).claimLaunch("Work") { nil }, .go)
    }

    func testASyncingClaimOfADeadProcessExpires() throws {
        let claims = make(pid: 100)
        _ = try claims.claimLaunch("Work") { nil }
        claims.setSyncing("Work", true)
        clock.addTimeInterval(25)
        alive = false
        XCTAssertEqual(try make(pid: 200).claimLaunch("Work") { nil }, .go)
    }

    func testTwoInstancesOnOneFileShareClaims() throws {
        let app = make(pid: 100), cli = make(pid: 200)
        XCTAssertEqual(try app.claimLaunch("Work") { nil }, .go)
        XCTAssertEqual(try cli.claimLaunch("work") { nil }, .starting)
        XCTAssertTrue(cli.startedRecently("WORK"))
    }

    func testDropStartingAllowsAnImmediateRetry() throws {
        let claims = make()
        XCTAssertEqual(try claims.claimLaunch("Work") { nil }, .go)
        claims.dropStarting("Work")
        XCTAssertFalse(claims.startedRecently("Work"))
        XCTAssertEqual(try claims.claimLaunch("Work") { nil }, .go)
    }

    func testWritingBlocksLaunchUntilDropped() throws {
        let claims = make(pid: 100), other = make(pid: 200)
        let work = profile("Work")
        try claims.claimWriting([work]) { _ in false }
        XCTAssertTrue(other.isWriting("Work"))
        XCTAssertEqual(try other.claimLaunch("Work") { nil }, .writing)
        claims.dropWriting([work])
        XCTAssertEqual(try other.claimLaunch("Work") { nil }, .go)
    }

    func testWritingClaimOfADeadProcessIsIgnored() throws {
        let claims = make(pid: 100), other = make(pid: 200)
        try claims.claimWriting([profile("Work")]) { _ in false }
        alive = false
        XCTAssertFalse(other.isWriting("Work"))
        XCTAssertEqual(try other.claimLaunch("Work") { nil }, .go)
    }

    func testWritingClaimOlderThan600SecondsIsIgnored() throws {
        let claims = make(pid: 100), other = make(pid: 200)
        try claims.claimWriting([profile("Work")]) { _ in false }
        clock.addTimeInterval(601)
        XCTAssertEqual(try other.claimLaunch("Work") { nil }, .go)
    }

    func testSecondWritingClaimIsRefused() throws {
        let claims = make()
        try claims.claimWriting([profile("Work")]) { _ in false }
        XCTAssertThrowsError(try claims.claimWriting([profile("Work")]) { _ in false })
    }

    func testClaimWritingRefusesAnOpenOrStartingProfileAndClaimsNothing() throws {
        let claims = make()
        let a = profile("A"), b = profile("B"), c = profile("C")
        XCTAssertThrowsError(try claims.claimWriting([a, b]) { $0.id == "B" })
        XCTAssertFalse(claims.isWriting("A"))
        XCTAssertEqual(try claims.claimLaunch("C") { nil }, .go)
        XCTAssertThrowsError(try claims.claimWriting([a, c]) { _ in false })
        XCTAssertFalse(claims.isWriting("A"))
    }

    func testCorruptClaimsFileDoesNotBlockALaunch() throws {
        try "garbage".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try make().claimLaunch("Work") { nil }, .go)
    }

    func testClaimsFileIsPrivate() throws {
        _ = try make().claimLaunch("Work") { nil }
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
