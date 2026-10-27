import AppKit
import SwitcherCore

enum CLI {
    static let valued: Set<String> = ["--launch", "--open-link", "--account", "--open-links-in", "--shortcut", "--claude-path", "--home",
                                      "--render-app-icon", "--render-panel-preview", "--lang"]
    static let flags: Set<String> = ["--list", "--add-account", "--status", "--route-sign-ins", "--revert", "--help", "-h", "--version"]

    /// The app bundle this binary lives in. Homebrew runs it through a symlink
    /// (`claude-profiles`), and then Bundle.main is not the app, so the real path comes
    /// from the kernel.
    static let appBundle: Bundle = {
        if Bundle.main.bundleIdentifier != nil { return .main }
        if let exe = ProcessScanner.executablePath(pid: getpid()) {
            let app = URL(fileURLWithPath: exe).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app", let bundle = Bundle(url: app), bundle.bundleIdentifier != nil { return bundle }
        }
        return .main
    }()

    /// Launch Services starts the app with no arguments, or with -psn_ (old systems) and
    /// -NS…/-Apple… user defaults (Xcode). Anything else is the command line, so a typo such
    /// as `claude-profiles list` is reported instead of starting a second menu bar app.
    static func handles(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        return !(first.hasPrefix("-psn_") || first.hasPrefix("-NS") || first.hasPrefix("-Apple"))
    }

    static let usage = """
    Claude Profile Switcher: several Claude desktop accounts side by side on one Mac.

    Without arguments it runs in the menu bar. Command line:

      --list                         Profiles and which are open
      --launch <name>                Open a profile, or bring it forward if it is open
      --add-account                  Add an account and open Claude at its sign-in screen
      --shortcut <name>              Make "Claude - <name>.app" in ~/Applications
      --status                       Sign-in routing state and open accounts
      --route-sign-ins               Send browser sign-ins to the account that asked
      --revert                       Turn sign-in routing off, give claude:// back to Claude
      --open-link <url> [--account <name>]
                                     Open a claude:// link in a chosen account
      --open-links-in <name>         Where claude:// links that are not sign-ins go
                                     while routing is on ("Default" undoes it)
      --claude-path <Claude.app>     Point at Claude if it is somewhere unusual (remembered)
    """

    static func run(_ args: [String]) -> Int32 {
        // The command line speaks English throughout, so one line never mixes two languages.
        Lang.turkish = false
        var options: [String: String] = [:]
        var switches: Set<String> = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if valued.contains(a) {
                guard i + 1 < args.count else { return fail("\(a) needs a value.\n\n\(usage)", code: 2) }
                options[a] = args[i + 1]
                i += 2
            } else if flags.contains(a) {
                switches.insert(a)
                i += 1
            } else {
                return fail("Unknown argument: \(a)\n\n\(usage)", code: 2)
            }
        }
        if switches.contains("--help") || switches.contains("-h") { print(usage); return 0 }
        if switches.contains("--version") {
            print(appBundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            return 0
        }
        // Used by the build script to draw the app icon.
        if let out = options["--render-app-icon"] {
            do { try Badge.writeICNS(to: URL(fileURLWithPath: out), render: AppIconArt.render) } catch { return fail(error.localizedDescription) }
            return 0
        }
        // Design review: the panel with sample accounts, as PNG files.
        if let out = options["--render-panel-preview"] {
            if let lang = options["--lang"] { Lang.turkish = lang.hasPrefix("tr") }
            do { try PanelPreview.render(to: URL(fileURLWithPath: out)) } catch { return fail(error.localizedDescription) }
            return 0
        }

        let paths = options["--home"].map { Paths(home: URL(fileURLWithPath: $0)) } ?? Paths()
        // Works without Claude, so routing can be turned off after Claude was removed.
        if switches.contains("--revert") {
            let done = Switcher.disableRouting(paths: paths, ownBundleID: appBundle.bundleIdentifier ?? "io.github.onlyilkr.ClaudeProfileSwitcher")
            print(done.isEmpty ? "Nothing to put back: sign-in routing had not changed anything." : done.map { "- \($0)" }.joined(separator: "\n"))
            return 0
        }
        let sw: Switcher
        do { sw = try Switcher(paths: paths, ownBundleID: appBundle.bundleIdentifier, claudePath: options["--claude-path"]) } catch { return fail(error.localizedDescription) }
        if options["--claude-path"] != nil { sw.settings.set("ClaudePath", sw.claude.url.path) }

        do {
            if switches.contains("--list") { list(sw); return 0 }
            if switches.contains("--status") { status(sw); return 0 }
            if switches.contains("--route-sign-ins") {
                sw.enableRouting()
                print("Sign-in routing is on. Browser sign-ins now go to the account that asked for them.")
                if !menuBarAppRunning(sw) {
                    print("Keep the menu bar app running: Claude takes claude:// links back each time it starts, and the app takes them again.")
                }
                return 0
            }
            if let name = options["--open-links-in"] {
                if name.caseInsensitiveCompare(Profile.defaultID) == .orderedSame {
                    sw.settings.set("OpenLinksIn", nil)
                    print("claude:// links that are not sign-ins open in Default again.")
                    return 0
                }
                let target = try resolve(sw, name)
                sw.settings.set("OpenLinksIn", target.id)
                print("claude:// links that are not sign-ins now open in '\(target.name)'.")
                if !sw.routingOn { print("That takes effect once sign-in routing is on (--route-sign-ins).") }
                return 0
            }
            if let link = options["--open-link"] {
                guard SignInLinks.isSafe(link) else {
                    throw SwitcherError("That is not a link the switcher can open: it must be claude:// followed by ordinary URL characters, up to 2048 of them.")
                }
                let target = try options["--account"].map { try resolve(sw, $0) } ?? sw.otherLinkTarget() ?? sw.defaultProfile
                try launch(sw, target, link: link)
                print("Opened the link in '\(target.name)'.")
                return 0
            }
            if let name = options["--launch"] {
                try launch(sw, try resolve(sw, name))
                retakeWhileStarting(sw)
                return 0
            }
            if switches.contains("--add-account") {
                let created = try sw.store.create(name: sw.store.nextAccountName())
                try launch(sw, created)
                print("Added '\(created.name)'. Sign in with the other account in the Claude window that just opened.")
                retakeWhileStarting(sw)
                return 0
            }
            if let name = options["--shortcut"] {
                let target = try resolve(sw, name)
                print(try sw.createLauncher(target).path)
                return 0
            }
        } catch {
            return fail(error.localizedDescription)
        }
        print(usage)
        return 0
    }

    // MARK: Commands

    static func list(_ sw: Switcher) {
        for p in sw.store.list(status: true) {
            let name = p.name == p.id ? p.name : "\(p.name) [\(p.id)]"
            let state = p.pid.map { "running (pid \($0))" } ?? "stopped"
            print(name.padding(toLength: max(24, name.count + 1), withPad: " ", startingAt: 0)
                  + state.padding(toLength: 22, withPad: " ", startingAt: 0) + p.path.path)
        }
    }

    static func status(_ sw: Switcher) {
        print("Claude:           \(sw.claude.url.path) (\(sw.claude.version))")
        print("Sign-in routing:  \(sw.routerStateText)")
        print("claude:// opens:  \(LinkHandler.current(scheme: "claude") ?? "nothing")")
        print("Pending sign-in:  \(sw.pending.get() ?? "none")")
        print("Other links:      open in '\(sw.otherLinkTarget()?.name ?? Profile.defaultID)'")
        print("Router log:       \(sw.paths.routerLog.path)")
        print("")
        print("Open accounts:")
        for p in sw.store.list(status: true) where p.isRunning {
            let state: String
            switch SignInState.signedIn(profileDir: p.path) {
            case true?: state = "signed in"
            case false?: state = "signed out"
            case nil: state = "unknown"
            }
            print("  \(p.name.padding(toLength: 24, withPad: " ", startingAt: 0)) pid \(String(p.pid!).padding(toLength: 7, withPad: " ", startingAt: 0)) \(state)")
        }
    }

    // MARK: Helpers

    static func resolve(_ sw: Switcher, _ name: String) throws -> Profile {
        if let hit = sw.store.resolve(name) { return hit }
        // Used to create a fresh, empty profile, so a typo quietly became a new account.
        let known = sw.store.list(status: false).map(\.name).joined(separator: ", ")
        throw SwitcherError("There is no Claude profile called '\(name)'.\n\nProfiles: \(known)")
    }

    /// Launches and waits for Launch Services to answer, running the main run loop so
    /// NSWorkspace and timers work. A failure or no answer in 30 s is an error (exit 1).
    static func launch(_ sw: Switcher, _ target: Profile, link: String? = nil) throws {
        var outcome: Result<Switcher.LaunchResult, Error>?
        sw.launch(target, link: link) { outcome = $0 }
        let until = Date().addingTimeInterval(30)
        while outcome == nil, Date() < until {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        switch outcome {
        case .success(.focused)?: print("Brought '\(target.name)' forward.")
        case .success?: break
        case .failure(let error)?: throw SwitcherError("Could not open '\(target.name)': \(error.localizedDescription)")
        case nil: throw SwitcherError("Could not open '\(target.name)': macOS did not answer within 30 seconds.")
        }
    }

    /// Claude rewrites the claude:// handler a few seconds into starting. Without the menu
    /// bar app to take it back, a command line launch stays a little while to do it.
    static func retakeWhileStarting(_ sw: Switcher) {
        guard sw.routingOn, !menuBarAppRunning(sw) else { return }
        let until = Date().addingTimeInterval(20)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1))
            sw.retakeRouterIfNeeded()
        }
    }

    static func menuBarAppRunning(_ sw: Switcher) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: sw.ownBundleID).contains { $0.processIdentifier != getpid() }
    }

    static func fail(_ message: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return code
    }
}
