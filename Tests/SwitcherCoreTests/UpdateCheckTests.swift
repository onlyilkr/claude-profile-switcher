import XCTest
@testable import SwitcherCore

final class UpdateCheckTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("update-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func release(_ tag: Any, draft: Bool = false, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease,
                                                     "html_url": "https://example.com/elsewhere"])
    }

    // MARK: versions

    func testVersionsParseStrictly() {
        XCTAssertEqual(AppVersion("1.2.0")?.description, "1.2.0")
        XCTAssertEqual(AppVersion("v10.0.3")?.description, "10.0.3")
        for bad in ["", "1.2", "1.2.0.1", "v1.2.0-rc.1", "1.2.x", " 1.2.0", "1.2.0\n", "x1.2.0", "1.2.0/../../a", "999999999999999999999.0.0"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    func testVersionsCompareByNumberNotText() {
        XCTAssertLessThan(AppVersion("1.9.0")!, AppVersion("1.10.0")!)
        XCTAssertLessThan(AppVersion("1.2.9")!, AppVersion("1.3.0")!)
        XCTAssertEqual(AppVersion("v1.2.0"), AppVersion("1.2.0"))
    }

    // MARK: the response

    func testTheLatestReleaseIsReadFromItsTagOnly() {
        XCTAssertEqual(UpdateCheck.latest(from: release("v1.3.0")), AppVersion("1.3.0"))
    }

    func testDraftsPrereleasesAndOddTagsAreIgnored() {
        XCTAssertNil(UpdateCheck.latest(from: release("v1.3.0", draft: true)))
        XCTAssertNil(UpdateCheck.latest(from: release("v1.3.0", prerelease: true)))
        XCTAssertNil(UpdateCheck.latest(from: release("v1.3.0-rc.1")))
        XCTAssertNil(UpdateCheck.latest(from: release(13)))
        XCTAssertNil(UpdateCheck.latest(from: Data("not json".utf8)))
        XCTAssertNil(UpdateCheck.latest(from: Data("[]".utf8)))
    }

    func testOnlyANewerReleaseIsOffered() {
        XCTAssertEqual(UpdateCheck.newer(than: "1.2.0", latest: AppVersion("1.3.0")), AppVersion("1.3.0"))
        XCTAssertNil(UpdateCheck.newer(than: "1.3.0", latest: AppVersion("1.3.0")))
        XCTAssertNil(UpdateCheck.newer(than: "1.4.0", latest: AppVersion("1.3.0")))
        XCTAssertNil(UpdateCheck.newer(than: "dev", latest: AppVersion("1.3.0")), "a build without a version never nags")
        XCTAssertNil(UpdateCheck.newer(than: "1.2.0", latest: nil))
    }

    /// The page opened comes from the checked version, never from a URL in the response.
    func testTheReleasePageIsBuiltFromTheVersion() {
        XCTAssertEqual(UpdateCheck.releasePage(AppVersion("1.3.0")!).absoluteString,
                       "https://github.com/onlyilkr/claude-profile-switcher/releases/tag/v1.3.0")
    }

    // MARK: when

    func testAtMostOnceADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(86_400 * 3), now: now), "a clock set back does not stop checks for days")
    }

    // MARK: state

    func testTheStateKeepsTheLastCheckTheLatestAndTheDismissedVersion() {
        let file = home.appendingPathComponent("update-check.json")
        let state = UpdateState(file: file)
        XCTAssertNil(state.lastCheck)
        state.lastCheck = Date(timeIntervalSince1970: 1_000)
        state.latest = AppVersion("1.3.0")
        state.dismissed = AppVersion("1.3.0")
        state.save()
        let again = UpdateState(file: file)
        XCTAssertEqual(again.lastCheck, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(again.latest, AppVersion("1.3.0"))
        XCTAssertEqual(again.dismissed, AppVersion("1.3.0"))
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testANoteIsShownUntilThatVersionIsDismissed() {
        let state = UpdateState(file: home.appendingPathComponent("u.json"))
        state.latest = AppVersion("1.3.0")
        XCTAssertEqual(state.offer(current: "1.2.0"), AppVersion("1.3.0"))
        state.dismissed = AppVersion("1.3.0")
        XCTAssertNil(state.offer(current: "1.2.0"))
        state.latest = AppVersion("1.4.0")
        XCTAssertEqual(state.offer(current: "1.2.0"), AppVersion("1.4.0"), "a newer release comes back")
        XCTAssertNil(state.offer(current: "1.4.0"), "gone once installed")
    }

    // MARK: checking

    func testACheckRecordsTheResultAndSendsNothingButTheVersion() {
        let state = UpdateState(file: home.appendingPathComponent("u.json"))
        var requests: [URLRequest] = []
        let now = Date(timeIntervalSince1970: 5_000_000)
        let found = UpdateCheck.run(state: state, current: "1.2.0", now: now) { request in
            requests.append(request)
            return .success((self.release("v1.3.0"), 200))
        }
        XCTAssertEqual(found, AppVersion("1.3.0"))
        XCTAssertEqual(state.lastCheck, now)
        XCTAssertEqual(requests.count, 1)
        let r = requests[0]
        XCTAssertEqual(r.url, UpdateCheck.latestURL)
        XCTAssertEqual(r.httpMethod ?? "GET", "GET")
        XCTAssertNil(r.httpBody)
        XCTAssertEqual(r.value(forHTTPHeaderField: "User-Agent"), "ClaudeProfileSwitcher/1.2.0")
        XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    func testACheckIsSkippedUntilADayHasPassed() {
        let state = UpdateState(file: home.appendingPathComponent("u.json"))
        let now = Date(timeIntervalSince1970: 5_000_000)
        state.lastCheck = now.addingTimeInterval(-60)
        state.latest = AppVersion("1.3.0")
        var calls = 0
        let found = UpdateCheck.run(state: state, current: "1.2.0", now: now) { _ in calls += 1; return .success((Data(), 200)) }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(found, AppVersion("1.3.0"), "what the last check found still counts")
    }

    func testAFailedCheckKeepsWhatWasKnownAndRetriesLater() {
        let state = UpdateState(file: home.appendingPathComponent("u.json"))
        state.latest = AppVersion("1.3.0")
        let now = Date(timeIntervalSince1970: 5_000_000)
        for outcome: Result<(Data, Int), Error> in [.failure(URLError(.notConnectedToInternet)), .success((Data("{}".utf8), 500)),
                                                    .success((Data("{}".utf8), 200))] {
            let found = UpdateCheck.run(state: state, current: "1.2.0", now: now) { _ in outcome }
            XCTAssertEqual(found, AppVersion("1.3.0"))
        }
        // Not marked as checked: a failure is tried again an hour later rather than a day.
        XCTAssertNil(state.lastCheck)
    }

    // MARK: Homebrew

    func testAHomebrewInstallIsFoundByItsCaskroomFolder() throws {
        let prefix = home.appendingPathComponent("homebrew", isDirectory: true)
        XCTAssertNil(UpdateCheck.brew(prefixes: [prefix]))
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Caskroom/claude-profile-switcher"), withIntermediateDirectories: true)
        XCTAssertNil(UpdateCheck.brew(prefixes: [prefix]), "no brew executable")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let brew = prefix.appendingPathComponent("bin/brew")
        try Data("#!/bin/sh\n".utf8).write(to: brew)
        chmod(brew.path, 0o755)
        XCTAssertEqual(UpdateCheck.brew(prefixes: [prefix])?.path, brew.path)
    }

    func testTheUpgradeScriptRunsOnlyTheFixedCommand() {
        let script = UpdateCheck.upgradeScript(brew: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("'/opt/homebrew/bin/brew' upgrade --cask claude-profile-switcher"))
        XCTAssertTrue(script.contains("open -b io.github.onlyilkr.ClaudeProfileSwitcher"))
        // A path with a quote cannot break out of the command.
        let odd = UpdateCheck.upgradeScript(brew: URL(fileURLWithPath: "/a'b/bin/brew"))
        XCTAssertTrue(odd.contains("'/a'\\''b/bin/brew'"), odd)
    }
}
