import XCTest
@testable import SwitcherCore

final class LinkTests: XCTestCase {
    func testSafeLinks() {
        XCTAssertTrue(SignInLinks.isSafe("claude://claude.ai/sso-callback?code=abc_DEF-1&state=x%20y"))
        XCTAssertTrue(SignInLinks.isSafe("claude://login/google-auth?x=1"))
        XCTAssertFalse(SignInLinks.isSafe(""))
        XCTAssertFalse(SignInLinks.isSafe("https://claude.ai"))
        XCTAssertFalse(SignInLinks.isSafe("claude://a\"b"))
        XCTAssertFalse(SignInLinks.isSafe("claude://a b"))
        XCTAssertFalse(SignInLinks.isSafe("claude://a\\b"))
        XCTAssertFalse(SignInLinks.isSafe("claude://ok\n"), "a trailing newline must not slip past the end anchor")
        XCTAssertFalse(SignInLinks.isSafe("claude://" + String(repeating: "a", count: 2048)))
    }

    func testSignInLinks() {
        XCTAssertTrue(SignInLinks.isSignIn("claude://login/abc"))
        XCTAssertTrue(SignInLinks.isSignIn("claude://claude.ai/sso-callback"))
        XCTAssertTrue(SignInLinks.isSignIn("claude://claude.ai/sso-callback?code=1"))
        XCTAssertTrue(SignInLinks.isSignIn("claude://claude.ai/sso-callback/x"))
        XCTAssertFalse(SignInLinks.isSignIn("claude://claude.ai/sso-callbackother"))
        XCTAssertFalse(SignInLinks.isSignIn("claude://claude.ai/new"))
    }
}

final class RoutingTests: XCTestCase {
    func profile(_ id: String, pid: pid_t?) -> Profile {
        Profile(id: id, name: id, path: URL(fileURLWithPath: "/tmp/\(id)"), pid: pid)
    }

    func testPendingWins() {
        let c = [SignInRouting.Candidate(profile: profile("Work", pid: nil), signedIn: nil),
                 SignInRouting.Candidate(profile: profile("Home", pid: 20), signedIn: false)]
        XCTAssertEqual(SignInRouting.select(c, pendingID: "Work", frontmostPID: 20)?.profile.id, "Work")
    }

    func testPendingNeverDefault() {
        let c = [SignInRouting.Candidate(profile: profile(Profile.defaultID, pid: 1), signedIn: false)]
        XCTAssertNil(SignInRouting.select(c, pendingID: Profile.defaultID, frontmostPID: nil))
    }

    func testOnlySignedOutAccount() {
        let c = [SignInRouting.Candidate(profile: profile("A", pid: 10), signedIn: true),
                 SignInRouting.Candidate(profile: profile("B", pid: 11), signedIn: false),
                 SignInRouting.Candidate(profile: profile("C", pid: nil), signedIn: nil)]
        XCTAssertEqual(SignInRouting.select(c, pendingID: nil, frontmostPID: 10)?.profile.id, "B")
    }

    func testFrontmostWhenAmbiguous() {
        let c = [SignInRouting.Candidate(profile: profile("A", pid: 10), signedIn: false),
                 SignInRouting.Candidate(profile: profile("B", pid: 11), signedIn: false)]
        XCTAssertEqual(SignInRouting.select(c, pendingID: nil, frontmostPID: 11)?.profile.id, "B")
        XCTAssertNil(SignInRouting.select(c, pendingID: nil, frontmostPID: 99))
    }

    func testPendingMarkerExpires() throws {
        let dir = try tempDir()
        let marker = PendingSignIn(file: dir.appendingPathComponent("p.json"))
        let now = Date()
        marker.set("Work", minutes: 15, now: now)
        XCTAssertEqual(marker.get(now: now.addingTimeInterval(60)), "Work")
        XCTAssertNil(marker.get(now: now.addingTimeInterval(16 * 60)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.file.path), "an expired marker is cleared")
    }

    func testSignedInDetection() {
        XCTAssertEqual(SignInState.signedIn(configData: Data(#"{"windowSizeWasSignedIn":false}"#.utf8)), false)
        XCTAssertEqual(SignInState.signedIn(configData: Data(#"{"windowSizeWasSignedIn":true}"#.utf8)), true)
        let long = String(repeating: "x", count: 1500)
        XCTAssertEqual(SignInState.signedIn(configData: Data(#"{"oauth:tokenCacheV2":"\#(long)"}"#.utf8)), true)
        XCTAssertEqual(SignInState.signedIn(configData: Data(#"{"oauth:tokenCacheV2":"short"}"#.utf8)), false)
        XCTAssertEqual(SignInState.signedIn(configData: Data(#"{}"#.utf8)), false)
        XCTAssertNil(SignInState.signedIn(configData: Data("not json".utf8)))
    }
}

final class ProcessTests: XCTestCase {
    func procargs(_ argv: [String], env: [String], exec: String = "/Applications/Claude.app/Contents/MacOS/Claude") -> [UInt8] {
        var b: [UInt8] = []
        let argc = UInt32(argv.count)
        b += [UInt8(argc & 0xff), UInt8((argc >> 8) & 0xff), UInt8((argc >> 16) & 0xff), UInt8(argc >> 24)]
        b += Array(exec.utf8) + [0, 0, 0, 0]
        for s in argv + env { b += Array(s.utf8) + [0] }
        b += [0, 0]
        return b
    }

    func testParseProcArgs() {
        let argv = ["/Applications/Claude.app/Contents/MacOS/Claude", "--user-data-dir=/Users/a/Library/Application Support/ClaudeProfile-Work", ""]
        let parsed = ProcessScanner.parseProcArgs(procargs(argv, env: ["HOME=/Users/a", "PATH=/usr/bin"]))
        XCTAssertEqual(parsed?.args, argv, "spaces and an empty argument survive")
        XCTAssertEqual(parsed?.env, ["HOME=/Users/a", "PATH=/usr/bin"])
        XCTAssertNil(ProcessScanner.parseProcArgs([1, 0]))
        let argsOnly = ProcessScanner.parseProcArgs(procargs(argv, env: ["SECRET=x"]), environment: false)
        XCTAssertEqual(argsOnly?.args, argv)
        XCTAssertEqual(argsOnly?.env, [], "the environment is not decoded")
    }

    func testDataDir() {
        XCTAssertEqual(ProcessScanner.dataDir(args: ["Claude", "--user-data-dir=/a b/c"], env: []), "/a b/c")
        XCTAssertEqual(ProcessScanner.dataDir(args: ["Claude", "--user-data-dir=\"/q\""], env: []), "/q")
        // Signed Claude builds delete CLAUDE_USER_DATA_DIR and use the default folder.
        XCTAssertNil(ProcessScanner.dataDir(args: ["Claude"], env: ["CLAUDE_USER_DATA_DIR=/e"]))
        XCTAssertEqual(ProcessScanner.dataDir(args: ["Claude", "--user-data-dir=/s"], env: ["CLAUDE_USER_DATA_DIR=/e"]), "/s")
        XCTAssertNil(ProcessScanner.dataDir(args: ["Claude", "claude://x"], env: []))
        XCTAssertTrue(ProcessScanner.isHelper(args: ["Claude Helper", "--type=renderer"]))
    }

    func testReadsOwnProcess() {
        let mine = ProcessScanner.argsAndEnv(pid: getpid())
        XCTAssertNotNil(mine)
        XCTAssertEqual(mine?.args.count, CommandLine.arguments.count)
        XCTAssertEqual(ProcessScanner.executablePath(pid: getpid()).map { URL(fileURLWithPath: $0).lastPathComponent },
                       URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent)
    }
}

final class SettingsTests: XCTestCase {
    func testSplitArgs() {
        XCTAssertEqual(Settings.splitArgs("--enable-logging  --v=1"), ["--enable-logging", "--v=1"])
        XCTAssertEqual(Settings.splitArgs(#"--lang "fr FR" 'a b' x"#), ["--lang", "fr FR", "a b", "x"])
        XCTAssertEqual(Settings.splitArgs(#"--empty="""#), ["--empty="])
        XCTAssertEqual(Settings.splitArgs("   "), [])
    }

    func testProfileEnvAndArgs() throws {
        let s = Settings(file: try tempDir().appendingPathComponent("settings.json"))
        try s.set("ProfileEnv", ["Work": ["MY_VAR": "v", "1BAD": "x", "BAD-NAME": "y", "N": 3]])
        try s.set("ProfileArgs", ["Work": "--a --b", "Home": ["--lang", "fr FR"]])
        XCTAssertEqual(s.profileEnv("Work"), ["MY_VAR": "v", "N": "3"])
        XCTAssertEqual(s.profileEnv("Other"), [:])
        XCTAssertEqual(s.profileArgs("Work"), ["--a", "--b"])
        XCTAssertEqual(s.profileArgs("Home"), ["--lang", "fr FR"])
        XCTAssertEqual(s.profileArgs("None"), [])
    }

    func testBadge() throws {
        XCTAssertEqual(Badge.letter(for: "work"), "W")
        XCTAssertEqual(Badge.letter(for: "  2nd"), "2")
        XCTAssertEqual(Badge.letter(for: "çalışma"), "Ç")
        let s = Settings(file: try tempDir().appendingPathComponent("settings.json"))
        let a = Badge.colorIndex(for: "A", settings: s, alive: ["A"])
        let b = Badge.colorIndex(for: "B", settings: s, alive: ["A", "B"])
        XCTAssertNotEqual(a, b, "a new profile gets the least used colour")
        XCTAssertEqual(Badge.colorIndex(for: "A", settings: s, alive: ["A", "B"]), a, "and keeps it")
    }
}

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cps-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

final class PlanUsageTests: XCTestCase {
    func testReadsNewestSampleOfVersion2() {
        let json = #"{"version":2,"samples":[{"t":1700000000000,"org":"o","u":{"fh":10,"sd":5}},{"t":1700000600000,"org":"o","u":{"fh":62.4,"sd":30,"xu":0}},{"t":1699990000000,"org":"p","u":{"fh":99}}]}"#
        let usage = PlanUsage.latest(historyData: Data(json.utf8))
        XCTAssertEqual(usage?.session, 62)
        XCTAssertEqual(usage?.weekly, 30)
        XCTAssertEqual(usage?.measuredAt, Date(timeIntervalSince1970: 1_700_000_600))
    }

    func testReadsVersion1AndRejectsJunk() {
        XCTAssertEqual(PlanUsage.latest(historyData: Data(#"{"version":1,"samples":[{"t":1700000000000,"fh":40,"sd":null}]}"#.utf8))?.session, 40)
        XCTAssertNil(PlanUsage.latest(historyData: Data(#"{"version":2,"samples":[]}"#.utf8)))
        XCTAssertNil(PlanUsage.latest(historyData: Data(#"{"version":2,"samples":[{"t":1,"u":{}}]}"#.utf8)))
        XCTAssertNil(PlanUsage.latest(historyData: Data("[]".utf8)))
    }

    func testOldMeasurementsSayNothingAboutNow() {
        let measured = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = PlanUsage(measuredAt: measured, session: 80, weekly: 40)
        XCTAssertEqual(usage.session(at: measured.addingTimeInterval(4 * 3600)), 80)
        XCTAssertNil(usage.session(at: measured.addingTimeInterval(5 * 3600 + 1)), "the 5-hour window has certainly reset")
        XCTAssertEqual(usage.weekly(at: measured.addingTimeInterval(6 * 86400)), 40)
        XCTAssertNil(usage.weekly(at: measured.addingTimeInterval(8 * 86400)))
    }

    func testCurrentOnlyWithinTheFiveHourWindow() {
        let measured = Date(timeIntervalSince1970: 1_700_000_000)
        let weeklyOnly = PlanUsage(measuredAt: measured, session: nil, weekly: 40)
        XCTAssertTrue(weeklyOnly.isCurrent(at: measured.addingTimeInterval(4 * 3600)), "a recent sample without fh is not old")
        XCTAssertFalse(weeklyOnly.isCurrent(at: measured.addingTimeInterval(5 * 3600 + 1)))
    }
}

final class ReviewFixTests: XCTestCase {
    func testDataDirFollowsChromiumGrammar() {
        // Chromium switches take their value after "=" only; a separate word is a positional argument.
        XCTAssertNil(ProcessScanner.dataDir(args: ["Claude", "--user-data-dir", "/x"], env: []))
        XCTAssertEqual(ProcessScanner.dataDir(args: ["Claude", "-user-data-dir=/single"], env: []), "/single")
        XCTAssertEqual(ProcessScanner.dataDir(args: ["Claude", "--user-data-dir=/a", "--user-data-dir=/b"], env: []), "/b", "last one wins")
        XCTAssertNil(ProcessScanner.dataDir(args: ["Claude", "--", "--user-data-dir=/after"], env: []), "nothing after -- is a switch")
    }

    func testElectronRunAsNodeChildrenAreNotInstances() {
        XCTAssertTrue(ProcessScanner.isHelper(args: ["Claude", "/x/server.js"], env: ["ELECTRON_RUN_AS_NODE=1"]))
        XCTAssertFalse(ProcessScanner.isHelper(args: ["Claude", "--user-data-dir=/p"], env: ["HOME=/h"]))
        XCTAssertTrue(ProcessScanner.isHelper(args: ["Claude Helper", "--type=renderer"], env: []))
    }

    func testFolderKeysIgnoreCaseOnCaseInsensitiveVolumes() throws {
        let dir = try tempDir().appendingPathComponent("ClaudeProfile-Work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let upper = URL(fileURLWithPath: dir.path.replacingOccurrences(of: "ClaudeProfile-Work", with: "CLAUDEPROFILE-WORK"))
        XCTAssertEqual(ProfileStore.key(dir), ProfileStore.key(upper), "same folder, same key")
    }

    func testCarryPinsRefusesAConfigItCannotParse() throws {
        let home = try tempDir()
        let target = Profile(id: "Work", name: "Work", path: home.appendingPathComponent("t"))
        try FileManager.default.createDirectory(at: target.path, withIntermediateDirectories: true)
        // Truncated mid-edit. (Foundation tolerates a trailing comma, which then loses nothing.)
        let broken = Data(#"{"mcpServers": {"a": {"command": "x""#.utf8)
        try broken.write(to: ChatTransfer.configFile(target))
        let source = Profile(id: "Default", name: "Default", path: home.appendingPathComponent("s"))
        try FileManager.default.createDirectory(at: source.path, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["preferences": ["epitaxyPrefs": ["starred-local-code-sessions": ["local_a"]]]])
            .write(to: ChatTransfer.configFile(source))
        let session = CodeSession(file: home.appendingPathComponent("local_a.json"), sessionID: "a", cliSessionID: "c",
                                  priorCLISessionIDs: [], title: "t", folder: "", updated: Date(), hasTranscript: true)
        let transfer = ChatTransfer(transcriptsRoot: home)
        XCTAssertThrowsError(try transfer.carryPins(of: [session], from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: ChatTransfer.configFile(target)), broken, "the user's file is left exactly as it was")
    }

    func testPinBackupsAreNeverOverwritten() throws {
        let home = try tempDir()
        let target = Profile(id: "Work", name: "Work", path: home.appendingPathComponent("t"))
        let source = Profile(id: "Default", name: "Default", path: home.appendingPathComponent("s"))
        for p in [target, source] { try FileManager.default.createDirectory(at: p.path, withIntermediateDirectories: true) }
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["a": 1]]).write(to: ChatTransfer.configFile(target))
        try JSONSerialization.data(withJSONObject: ["preferences": ["epitaxyPrefs": ["starred-local-code-sessions": ["local_a", "local_b"]]]])
            .write(to: ChatTransfer.configFile(source))
        func session(_ id: String) -> CodeSession {
            CodeSession(file: home.appendingPathComponent("local_\(id).json"), sessionID: id, cliSessionID: "c\(id)",
                        priorCLISessionIDs: [], title: id, folder: "", updated: Date(), hasTranscript: true)
        }
        XCTAssertEqual(try ChatTransfer(transcriptsRoot: home).carryPins(of: [session("a")], from: source, to: target), 1)
        XCTAssertEqual(try ChatTransfer(transcriptsRoot: home).carryPins(of: [session("b")], from: source, to: target), 1)
        let backups = try FileManager.default.contentsOfDirectory(atPath: target.path.path).filter { $0.contains("switcher-backup") }
        XCTAssertEqual(backups.count, 2, "each change keeps its own backup")
    }

    func testSettingsRefuseToOverwriteAFileTheyCannotParse() throws {
        let file = try tempDir().appendingPathComponent("settings.json")
        let broken = Data(#"{"Labels": {"Work": "Office""#.utf8)
        try broken.write(to: file)
        let settings = Settings(file: file)
        XCTAssertNotNil(settings.problem)
        XCTAssertThrowsError(try settings.set("Colors", ["Work": 1]))
        XCTAssertEqual(try Data(contentsOf: file), broken, "a hand edit with a typo is never thrown away")
    }

    func testOneOddLabelDoesNotDropTheOthers() throws {
        let file = try tempDir().appendingPathComponent("settings.json")
        try Data(#"{"Labels": {"Work": "Office", "Home": 7}}"#.utf8).write(to: file)
        XCTAssertEqual(Settings(file: file).labels, ["Work": "Office"])
    }

    func testLauncherBundleIDsAreUniquePerProfile() {
        let ids = ["Account 2", "Account2", "İş", "Ölçü"].map { Launchers.bundleIDSuffix(for: $0) }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testPlanUsageSurvivesAbsurdNumbers() {
        XCTAssertEqual(PlanUsage.latest(historyData: Data(#"{"version":2,"samples":[{"t":1700000000000,"u":{"fh":1e300,"sd":-5}}]}"#.utf8))?.session, 100_000)
        XCTAssertEqual(PlanUsage.latest(historyData: Data(#"{"version":2,"samples":[{"t":1700000000000,"u":{"fh":1e300,"sd":-5}}]}"#.utf8))?.weekly, 0)
    }
}

final class LaunchArgumentTests: XCTestCase {
    /// Whatever ProfileArgs says, the folder Claude will use (as the scanner reads it back)
    /// is the profile's own: otherwise the one-copy-per-folder check looks at the wrong one.
    func testExtraFlagsCannotMoveTheDataFolder() {
        let work = Profile(id: "Work", name: "Work", path: URL(fileURLWithPath: "/Users/a/Library/Application Support/ClaudeProfile-Work"))
        let extra = ["--user-data-dir=/x", "-user-data-dir=/y", "--USER-DATA-DIR=/z", "--lang", "fr-FR"]
        let args = Switcher.launchArguments(for: work, extra: extra)
        XCTAssertEqual(ProcessScanner.dataDir(args: ["Claude"] + args, env: []), work.path.path)
        XCTAssertTrue(args.contains("--lang") && args.contains("fr-FR"), "other flags are kept")

        let original = Profile(id: Profile.defaultID, name: "Default", path: URL(fileURLWithPath: "/Users/a/Library/Application Support/Claude"))
        XCTAssertNil(ProcessScanner.dataDir(args: ["Claude"] + Switcher.launchArguments(for: original, extra: ["--user-data-dir=/x"]), env: []))
    }

    func testRenameRefusesWhenSettingsCannotBeSaved() throws {
        let paths = Paths(home: try tempDir())
        try FileManager.default.createDirectory(at: paths.switcherHome, withIntermediateDirectories: true)
        let store = ProfileStore(paths: paths, settings: Settings(file: paths.settingsFile)) { [:] }
        let work = try store.create(name: "Work")
        try Data(#"{"Labels": {"#.utf8).write(to: paths.settingsFile)
        XCTAssertThrowsError(try store.rename(work, to: "Office"), "a rename that cannot be saved must not look like it worked")
    }

    func testPinsAreWrittenThroughASymlinkedConfig() throws {
        let home = try tempDir()
        let shared = home.appendingPathComponent("shared-config.json")
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["a": 1]]).write(to: shared)
        let target = Profile(id: "Work", name: "Work", path: home.appendingPathComponent("t"))
        let source = Profile(id: "Default", name: "Default", path: home.appendingPathComponent("s"))
        for p in [target, source] { try FileManager.default.createDirectory(at: p.path, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: ChatTransfer.configFile(target), withDestinationURL: shared)
        try JSONSerialization.data(withJSONObject: ["preferences": ["epitaxyPrefs": ["starred-local-code-sessions": ["local_a"]]]])
            .write(to: ChatTransfer.configFile(source))
        let session = CodeSession(file: home.appendingPathComponent("local_a.json"), sessionID: "a", cliSessionID: "c",
                                  priorCLISessionIDs: [], title: "a", folder: "", updated: Date(), hasTranscript: true)
        XCTAssertEqual(try ChatTransfer(transcriptsRoot: home).carryPins(of: [session], from: source, to: target), 1)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: ChatTransfer.configFile(target).path)
        XCTAssertEqual(URL(fileURLWithPath: link).resolvingSymlinksInPath(), shared.resolvingSymlinksInPath(), "the link is kept")
        XCTAssertEqual(ChatTransfer(transcriptsRoot: home).pins(of: target), ["local_a"])
    }
}

final class AuditFixTests: XCTestCase {
    func testLoggedErrorsNeverCarryTheirMessage() {
        let link = "claude://login/ONE-TIME-CODE"
        let error = NSError(domain: "NSOSStatusErrorDomain", code: -10814,
                            userInfo: [NSLocalizedDescriptionKey: "The application can't open \(link)."])
        let line = Switcher.describe(error)
        XCTAssertFalse(line.contains("ONE-TIME-CODE"), "a sign-in code quoted by the OS must not reach a log")
        XCTAssertEqual(line, "NSOSStatusErrorDomain -10814")
    }

    func testLauncherCommentCannotEndTheLine() {
        for id in ["a\nb", "a\rb", "a\r\nb", "a\u{2028}b", "a\u{85}b", "a\u{0}b"] {
            let safe = Launchers.commentSafe(id)
            XCTAssertNil(safe.rangeOfCharacter(from: CharacterSet.newlines.union(.controlCharacters)), "\(id.debugDescription)")
        }
        XCTAssertEqual(Launchers.commentSafe("Account 2"), "Account 2")
    }

    func testPinsRefuseAConfigThatBelongsToAnOpenProfile() throws {
        let home = try tempDir()
        let other = home.appendingPathComponent("open-profile")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let shared = other.appendingPathComponent("claude_desktop_config.json")
        let original = try JSONSerialization.data(withJSONObject: ["mcpServers": ["a": 1]])
        try original.write(to: shared)
        let target = Profile(id: "Work", name: "Work", path: home.appendingPathComponent("t"))
        let source = Profile(id: "Default", name: "Default", path: home.appendingPathComponent("s"))
        for p in [target, source] { try FileManager.default.createDirectory(at: p.path, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: ChatTransfer.configFile(target), withDestinationURL: shared)
        try JSONSerialization.data(withJSONObject: ["preferences": ["epitaxyPrefs": ["starred-local-code-sessions": ["local_a"]]]])
            .write(to: ChatTransfer.configFile(source))
        let session = CodeSession(file: home.appendingPathComponent("local_a.json"), sessionID: "a", cliSessionID: "c",
                                  priorCLISessionIDs: [], title: "a", folder: "", updated: Date(), hasTranscript: true)
        XCTAssertThrowsError(try ChatTransfer(transcriptsRoot: home).carryPins(of: [session], from: source, to: target, openFolders: [other]))
        XCTAssertEqual(try Data(contentsOf: shared), original, "an open profile's config is left alone")
    }

    func testConcurrentAppendsKeepEveryLineWhole() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("router.log")
        DispatchQueue.concurrentPerform(iterations: 4) { thread in
            for n in 0..<100 { Switcher.append("t\(thread)-\(n)", to: log) }
        }
        let lines = try String(contentsOf: log).split(separator: "\n")
        XCTAssertEqual(lines.count, 400)
        XCTAssertTrue(lines.allSatisfy { $0.range(of: #"^\[[^\]]+\] t\d-\d+$"#, options: .regularExpression) != nil })
    }
}

final class UsageAgeTests: XCTestCase {
    func testAgeIsShortAndHonest() {
        Lang.turkish = false
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = PlanUsage(measuredAt: t, session: 40, weekly: nil)
        XCTAssertEqual(usage.age(at: t.addingTimeInterval(20)), "now")
        XCTAssertEqual(usage.age(at: t.addingTimeInterval(12 * 60 + 5)), "12m ago")
        XCTAssertEqual(usage.age(at: t.addingTimeInterval(3 * 3600 + 100)), "3h ago")
        XCTAssertEqual(usage.age(at: t.addingTimeInterval(-30)), "now", "a clock that moved back never shows a negative age")
        XCTAssertEqual(usage.age(at: t.addingTimeInterval(47 * 3600)), "47h ago")
        XCTAssertEqual(usage.age(at: t.addingTimeInterval(4 * 86400 + 100)), "4d ago")
        Lang.turkish = true
        XCTAssertEqual(usage.age(at: t.addingTimeInterval(12 * 60)), "12 dk önce")
        XCTAssertEqual(usage.age(at: t.addingTimeInterval(4 * 86400)), "4 gün önce")
        Lang.turkish = false
    }

    func testUsageLinkIsOneTheSwitcherAccepts() {
        XCTAssertTrue(SignInLinks.isSafe(Switcher.usageLink))
        XCTAssertFalse(SignInLinks.isSignIn(Switcher.usageLink), "never treated as a sign-in")
    }
}
