import XCTest
@testable import SwitcherCore

/// A `Switcher` on a temp home with a stand-in Claude.app, so nothing real is launched or touched.
final class SwitcherWritingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-writing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeSwitcher() throws -> (Switcher, Profile) {
        let app = dir.appendingPathComponent("Claude.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": ClaudeApp.bundleID, "CFBundleExecutable": "Claude", "CFBundleShortVersionString": "1.0"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        let exe = app.appendingPathComponent("MacOS/Claude")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let paths = Paths(home: dir.appendingPathComponent("home", isDirectory: true))
        let sw = try Switcher(paths: paths, ownBundleID: "test.switcher", claudePath: dir.appendingPathComponent("Claude.app").path)
        let folder = paths.profileDir(id: "work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let profile = try XCTUnwrap(sw.store.list(status: true).first { $0.id == "work" })
        return (sw, profile)
    }

    private func otherWriter(_ sw: Switcher) -> ProfileClaims {
        ProfileClaims(file: sw.paths.claimsFile, ownPID: getppid())
    }

    func testAProfileBeingWrittenCountsAsOpenUntilTheClaimIsDropped() throws {
        let (sw, profile) = try makeSwitcher()
        XCTAssertFalse(sw.openFolders().contains { ProfileStore.sameItem($0, profile.path) })
        let other = otherWriter(sw)
        try other.claimWriting([profile]) { _ in false }
        XCTAssertTrue(sw.openFolders().contains { ProfileStore.sameItem($0, profile.path) })
        other.dropWriting([profile])
        XCTAssertFalse(sw.openFolders().contains { ProfileStore.sameItem($0, profile.path) })
    }

    func testDeleteIsRefusedWhileTheProfileIsBeingWritten() throws {
        let (sw, profile) = try makeSwitcher()
        let other = otherWriter(sw)
        try other.claimWriting([profile]) { _ in false }
        XCTAssertThrowsError(try sw.delete(profile)) { XCTAssertTrue($0.localizedDescription.contains("being updated")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path.path))
        other.dropWriting([profile])
        sw.store.remove = { try FileManager.default.removeItem(at: $0) }  // not the real Trash
        XCTAssertNoThrow(try sw.delete(profile))
    }

    // MARK: Launch refusal after a failed restore, and the panel notes

    func testARefusedLaunchAnswersOnTheMainThreadAndDropsTheClaim() throws {
        let (sw, profile) = try makeSwitcher()
        sw.restoreFailures.set(profile.id, backup: "/backup/place")   // the profile has no readable storage at all
        let done = expectation(description: "completion")
        var failure: Error?
        var onMain = false
        sw.launch(profile) { result in
            onMain = Thread.isMainThread
            if case .failure(let e) = result { failure = e }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(onMain)
        XCTAssertTrue((failure as? SwitcherError)?.message.contains("/backup/place") == true, "names the backup folder")
        XCTAssertFalse(sw.claims.startedRecently(profile.id), "the starting claim is dropped")
        XCTAssertNotNil(sw.restoreFailures.backup(for: profile.id), "the marker stays until the store reads clean")
        XCTAssertTrue(sw.pinSyncProblems[profile.id]?.contains("/backup/place") == true, "and the panel shows it")
    }

    func testTwoAccountsWithTheSameRefusalGetDistinctNotes() throws {
        let a = Profile(id: "a", name: "Alpha", path: dir.appendingPathComponent("a"))
        let b = Profile(id: "b", name: "Beta", path: dir.appendingPathComponent("b"))
        for reason in ["no pin record yet", "pin store format not recognised", "leveldb read failed", "leveldb compression not supported"] {
            let e = SwitcherError("generic", logReason: reason)
            let na = try XCTUnwrap(Switcher.pinSyncNote(for: e, target: a)), nb = try XCTUnwrap(Switcher.pinSyncNote(for: e, target: b))
            XCTAssertNotEqual(na, nb, reason)
            XCTAssertTrue(na.contains("Alpha") && nb.contains("Beta"), reason)
        }
        // "no pin record yet" arrives with the account's name already in its message.
        XCTAssertTrue(Switcher.pinSyncNote(for: PinSync.noPinRecord(a), target: a)!.contains("Alpha"))
    }

    func testANoteOfADeletedProfileIsGone() throws {
        let (sw, profile) = try makeSwitcher()
        sw.pinSyncNotes.set(profile.id, "a note")
        sw.pinSyncNotes.set("gone", "stale note")
        XCTAssertEqual(sw.pinSyncProblems, [profile.id: "a note"])
    }
}
