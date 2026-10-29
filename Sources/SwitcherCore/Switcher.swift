import AppKit

/// Everything the menu bar and the command line do, in one place.
public final class Switcher {
    public enum LaunchResult { case focused, started, starting }

    public let paths: Paths
    public let settings: Settings
    public let ownBundleID: String
    public private(set) var claude: ClaudeApp
    public let store: ProfileStore
    public let pending: PendingSignIn
    public let launchers: Launchers
    public let transfer: ChatTransfer

    /// Launches that were started but may not show up as a process yet, shared with the command line through a file.
    /// Starting a profile twice in that window would put two copies on one folder.
    public let claims: ProfileClaims

    public init(paths: Paths = Paths(), ownBundleID: String? = nil, claudePath: String? = nil) throws {
        self.paths = paths
        self.settings = Settings(file: paths.settingsFile)
        self.ownBundleID = ownBundleID ?? Bundle.main.bundleIdentifier ?? "io.github.onlyilkr.ClaudeProfileSwitcher"
        self.claude = try claudePath.map { try ClaudeApp.locate(override: $0, strict: true) } ?? ClaudeApp.locate(override: settings.claudePath)
        self.pending = PendingSignIn(file: paths.pendingSignIn)
        self.launchers = Launchers(dir: paths.launcherDir, ownBundleID: self.ownBundleID)
        self.transfer = ChatTransfer(transcriptsRoot: paths.transcriptsRoot)
        self.claims = ProfileClaims(file: paths.claimsFile)
        let defaultFolder = paths.defaultProfile
        // By bundle id, so any copy of Claude counts, wherever it was started from.
        self.store = ProfileStore(paths: paths, settings: settings) {
            ProfileStore.runningMap(bundleID: ClaudeApp.bundleID, defaultFolder: defaultFolder)
        }
    }

    public func refreshClaude() {
        if !FileManager.default.isExecutableFile(atPath: claude.executable), let again = try? ClaudeApp.locate(override: settings.claudePath) {
            claude = again
        }
    }

    public var defaultProfile: Profile { store.resolve(Profile.defaultID)! }

    /// Claude's Settings > Usage page, as a link Claude routes inside its own window.
    public static let usageLink = "claude://claude.ai/settings/usage"

    // MARK: Launching

    /// Opens a profile, or brings it forward when it is already open. A link goes along:
    /// to an open copy as an Apple Event addressed to its pid, to a new copy at launch.
    /// `expectSignIn`: this launch comes from the user (panel, command line), so a profile
    /// that is signed out is the one waiting for the next sign-in. Launches requested by a
    /// URL pass false: any web page can send one, and it must not steer sign-ins.
    public func launch(_ target: Profile, link: String? = nil, expectSignIn: Bool = true,
                       completion: ((Result<LaunchResult, Error>) -> Void)? = nil) {
        refreshClaude()
        if !target.isDefault {
            do {
                try FileManager.default.createDirectory(at: target.path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                completion?(.failure(error))
                return
            }
        }
        // One decision for the whole machine: the running check and the claim happen under one lock.
        let decision: ProfileClaims.LaunchDecision
        do {
            decision = try claims.claimLaunch(target.id) { store.isRunning(target) }
        } catch {
            completion?(.failure(error))
            return
        }
        switch decision {
        case .running(let pid):
            claims.dropStarting(target.id)
            if let link { send(link, to: pid) }
            Focus.bring(pid: pid)
            completion?(.success(.focused))
            return
        case .starting:
            if let link { whenRunning(target) { self.send(link, to: $0) } }
            completion?(.success(.starting))
            return
        case .writing:
            completion?(.failure(SwitcherError(L("'\(target.name)' is being updated by the switcher. Try again in a moment.",
                                                 "'\(target.name)' switcher tarafından güncelleniyor. Birazdan tekrar deneyin."))))
            return
        case .go:
            break
        }
        // A profile that is not signed in yet is about to be: its sign-in is the one to expect.
        if expectSignIn, routingOn, SignInState.signedIn(profileDir: target.path) != true { pending.set(target.id) }

        let config = NSWorkspace.OpenConfiguration()
        // Always a new copy: with any Claude already running, Launch Services would
        // otherwise just bring that one forward, whichever account it is.
        config.createsNewApplicationInstance = true
        config.activates = true
        config.addsToRecentItems = false
        config.arguments = Switcher.launchArguments(for: target, extra: settings.profileArgs(target.id))
        let env = settings.profileEnv(target.id)
        if !env.isEmpty { config.environment = env }

        syncPinsBeforeLaunch(target)

        let done: (NSRunningApplication?, Error?) -> Void = { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.claims.dropStarting(target.id)
                    completion?(.failure(error))
                } else {
                    completion?(.success(.started))
                }
            }
        }
        if let link, let url = URL(string: link) {
            NSWorkspace.shared.open([url], withApplicationAt: claude.url, configuration: config, completionHandler: done)
        } else {
            NSWorkspace.shared.openApplication(at: claude.url, configuration: config, completionHandler: done)
        }
    }

    /// Before an account opens: its pins for chats it shares follow the account used last.
    /// Never blocks the launch; a failure is logged (no chat ids or titles) and the launch goes on.
    private func syncPinsBeforeLaunch(_ target: Profile) {
        guard settings.syncPins else { return }
        let profiles = store.list(status: true)
        // The target holds its own starting claim by now; it counts as open only when it is really running.
        let open = profiles.filter { $0.isRunning || ($0.id != target.id && isStarting($0)) }.map(\.path)
        Switcher.syncPinsBeforeLaunch(target: target, among: profiles, openFolders: open, enabled: true, transfer: transfer,
                                      lastUsed: { ProfileStore.lastUsed($0.path) },
                                      log: { self.log($0) }, logError: { self.logError($0) })
    }

    /// The part of the launch that is testable without Claude. `openFolders` are the running and
    /// starting profiles; a target among them is left alone.
    static func syncPinsBeforeLaunch(target: Profile, among: [Profile], openFolders: [URL], enabled: Bool, transfer: ChatTransfer,
                                     lastUsed: (Profile) -> Date?, log: (String) -> Void, logError: (String) -> Void) {
        guard enabled else { return }
        let key = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path }
        if openFolders.contains(where: { key($0) == key(target.path) }) { return }
        let targetIDs = transfer.chatIDs(in: target)
        guard let source = PinSync.source(for: target, among: among, lastUsed: lastUsed, transfer: transfer, targetIDs: targetIDs) else { return }
        do {
            guard let plan = PinSync.plan(target: target, source: source, transfer: transfer, targetIDs: targetIDs) else { return }
            try PinSync.apply(plan, to: target, transfer: transfer, openFolders: openFolders)
            let pinned = plan.newPins.filter { !plan.seenPins.contains($0) }.count, unpinned = plan.seenPins.filter { !plan.newPins.contains($0) }.count
            log("Pins synced from '\(source.name)' to '\(target.name)' (\(pinned) pinned, \(unpinned) unpinned)")
        } catch {
            // Fixed, path-free reasons only: the user-facing messages quote file paths and the log is pasted into bug reports.
            let reason = (error as? SwitcherError)?.logReason ?? Switcher.describe(error)
            logError("Pin sync for '\(target.name)' failed: \(reason)")
        }
    }

    /// The folders of every profile that is running or starting: nothing may be written to these.
    /// Safe to call from any thread.
    public func openFolders() -> [URL] {
        store.list(status: true).filter { $0.isRunning || isStarting($0) }.map(\.path)
    }

    /// Launched (from here or the command line) in the last 20 s and not visible as a process yet. Treated as
    /// open by everything that must not touch an open profile.
    public func isStarting(_ target: Profile) -> Bool {
        claims.startedRecently(target.id) && store.isRunning(target) == nil
    }

    /// Runs `body` with every profile claimed for writing, so no launch (here or from the command line) starts one
    /// meanwhile. Throws when one is open, starting or already being written.
    public func whileWriting<T>(_ profiles: [Profile], _ body: () throws -> T) throws -> T {
        try claims.claimWriting(profiles) { self.store.isRunning($0) != nil || self.claims.startedRecently($0.id) }
        defer { claims.dropWriting(profiles) }
        return try body()
    }

    /// The profile's folder, then its ProfileArgs without any data folder switch of their
    /// own: Chromium uses the last one, so a stray --user-data-dir there would move the
    /// account to a folder the "is it open?" check never looks at.
    public static func launchArguments(for target: Profile, extra: [String]) -> [String] {
        let kept = extra.filter { arg in
            let name = arg.drop { $0 == "-" }.lowercased()
            return !(arg.hasPrefix("-") && (name == "user-data-dir" || name.hasPrefix("user-data-dir=")))
        }
        return (target.isDefault ? [] : ["--user-data-dir=\(target.path.path)"]) + kept
    }

    public func addAccount(completion: ((Result<LaunchResult, Error>) -> Void)? = nil) throws -> Profile {
        let created = try store.create(name: store.nextAccountName())
        // Straight to the sign-in screen: there is nothing else to do with an empty profile.
        launch(created, completion: completion)
        return created
    }

    /// Calls back with the pid once the profile's process shows up, for up to 20 s.
    public func whenRunning(_ target: Profile, timeout: TimeInterval = 20, then: @escaping (pid_t) -> Void) {
        let until = Date().addingTimeInterval(timeout)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            if let pid = self.store.isRunning(target) { timer.invalidate(); then(pid) }
            else if Date() > until { timer.invalidate() }
        }
    }

    private func send(_ link: String, to pid: pid_t) {
        // The pid came from a scan moments ago; make sure it is still that Claude, so a
        // link (and its one-time code) never goes to a process that took over the number.
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier == ClaudeApp.bundleID else {
            log("Did not hand a link to Claude: the copy quit before it could be delivered.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if let error = AppleEvents.openURL(link, pid: pid) {
                self.log(AppleEvents.isNotPermitted(error)
                         ? "Could not hand a link to Claude: Automation permission was refused (System Settings > Privacy & Security > Automation)."
                         : "Could not hand a link to Claude: \(Switcher.describe(error))")
            }
        }
    }

    /// Asks one copy to quit, and reports whether it did within the time given.
    public func quit(_ target: Profile, timeout: TimeInterval = 30, completion: @escaping (Bool) -> Void) {
        guard let pid = store.isRunning(target), let app = NSRunningApplication(processIdentifier: pid) else { completion(true); return }
        app.terminate()
        let until = Date().addingTimeInterval(timeout)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            // Gone means gone from the kernel, not just from Launch Services' list: the copy
            // writes its chat list and pins while it quits.
            if kill(pid, 0) != 0, errno == ESRCH { timer.invalidate(); completion(true) }
            else if Date() > until { timer.invalidate(); completion(false) }
        }
    }

    // MARK: Rename, delete, launchers

    public func rename(_ target: Profile, to newName: String) throws -> Profile {
        let hadLauncher = launchers.exists(label: target.name)
        let renamed = try store.rename(target, to: newName)
        // Launchers are named after the label, so put back the one just made stale.
        if hadLauncher {
            launchers.remove(label: target.name)
            _ = try? createLauncher(renamed)
        }
        return renamed
    }

    public func delete(_ target: Profile) throws {
        if isStarting(target) {
            throw SwitcherError(L("'\(target.name)' is starting. Quit it before deleting it.", "'\(target.name)' açılıyor. Silmeden önce kapatın."))
        }
        try store.delete(target)
        launchers.remove(label: target.name)
    }

    @discardableResult
    public func createLauncher(_ target: Profile) throws -> URL {
        let base = NSWorkspace.shared.icon(forFile: claude.url.path)
        let letter = target.isDefault ? nil : Badge.letter(for: target.name)
        let color = target.isDefault ? nil : badgeColor(target)
        return try launchers.create(profile: target) { Badge.badged(base: base, letter: letter, color: color, pixels: $0) }
    }

    public func badgeColor(_ target: Profile) -> NSColor {
        Badge.color(index: Badge.colorIndex(for: target.id, settings: settings, alive: store.ids()))
    }

    // MARK: Sign-in routing

    public var routingOn: Bool { settings.signInRouting == true }

    public var routerRegistered: Bool {
        LinkHandler.current(scheme: "claude")?.caseInsensitiveCompare(ownBundleID) == .orderedSame
    }

    /// Makes the switcher the app macOS opens claude:// links with. Claude takes that back
    /// every time it starts, so the menu bar app takes it again whenever it notices.
    public func enableRouting() {
        if settings["RouterBackup"] == nil, let current = LinkHandler.current(scheme: "claude"),
           current.caseInsensitiveCompare(ownBundleID) != .orderedSame {
            try? settings.set("RouterBackup", current)
        }
        LinkHandler.set(scheme: "claude", bundleID: ownBundleID)
        try? settings.set("SignInRouting", true)
        log("Sign-in routing turned on.")
    }

    /// Returns one line per thing done.
    public func disableRouting() -> [String] {
        Switcher.disableRouting(paths: paths, ownBundleID: ownBundleID)
    }

    /// Needs no Claude, so routing can be turned off after Claude was removed.
    public static func disableRouting(paths: Paths, ownBundleID: String) -> [String] {
        let settings = Settings(file: paths.settingsFile)
        PendingSignIn(file: paths.pendingSignIn).clear()
        var done: [String] = []
        // The handler goes back first: it is what matters even when settings.json cannot be saved.
        if LinkHandler.current(scheme: "claude")?.caseInsensitiveCompare(ownBundleID) == .orderedSame {
            let original = (settings["RouterBackup"] as? String) ?? ClaudeApp.bundleID
            LinkHandler.set(scheme: "claude", bundleID: original)
            done.append(L("gave claude:// links back to \(original)", "claude:// linkleri yeniden \(original) uygulamasına verildi"))
        }
        do {
            try settings.set("SignInRouting", false)
            try settings.set("RouterBackup", nil)
        } catch {
            done.append(L("could not update settings.json: \(error.localizedDescription)", "settings.json güncellenemedi: \(error.localizedDescription)"))
        }
        append("Sign-in routing turned off.", to: paths.routerLog)
        return done
    }

    /// Called on a timer. True when the handler had to be taken back.
    @discardableResult
    public func retakeRouterIfNeeded() -> Bool {
        if routingOn, !routerRegistered {
            LinkHandler.set(scheme: "claude", bundleID: ownBundleID)
            log("Took the claude:// handler back.")
            return true
        }
        // Left over from a crash or a copy that was removed while routing was on.
        if !routingOn, routerRegistered {
            LinkHandler.set(scheme: "claude", bundleID: (settings["RouterBackup"] as? String) ?? ClaudeApp.bundleID)
        }
        return false
    }

    public var routerStateText: String {
        if !routingOn { return L("off", "kapalı") }
        if !routerRegistered { return L("on, but Claude has the claude:// handler back (taken again within seconds while the switcher runs)",
                                        "açık, ama claude:// işleyicisi Claude'a geçmiş (switcher çalışırken birkaç saniyede geri alınır)") }
        return L("on: sign-ins go to the account that asked", "açık: girişler isteyen hesaba gider")
    }

    /// Where a claude:// link that is not a sign-in goes: the account OpenLinksIn names,
    /// or nil for Default.
    public func otherLinkTarget() -> Profile? {
        guard let id = settings.openLinksIn, id != Profile.defaultID, let target = store.resolve(id), !target.isDefault else { return nil }
        return target
    }

    /// A routed link must not get lost: if the chosen account cannot be opened, the link
    /// goes to Default, as it would have without routing.
    private func deliver(_ link: String, to target: Profile) {
        launch(target, link: link, expectSignIn: false) { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            self.logError("Could not open '\(target.name)' for a claude:// link: \(Switcher.describe(error))")
            if !target.isDefault {
                self.log("Passed the link to Default instead.")
                self.launch(self.defaultProfile, link: link, expectSignIn: false)
            }
        }
    }

    /// Handles a claude:// link Launch Services gave the switcher. Never logs the link
    /// itself: a sign-in link carries a one-time code.
    public func handleClaudeLink(_ link: String) {
        guard SignInLinks.isSafe(link) else {
            log("Refused a claude:// link that failed validation.")
            return
        }
        guard routingOn else {
            deliver(link, to: defaultProfile)
            log("Routing is off; passed a link to Default.")
            return
        }
        guard SignInLinks.isSignIn(link) else {
            if let other = otherLinkTarget() {
                deliver(link, to: other)
                log("Not a sign-in link; opened in '\(other.name)' (OpenLinksIn).")
            } else {
                deliver(link, to: defaultProfile)
                log("Not a sign-in link; passed to Default.")
            }
            return
        }
        let profiles = store.list(status: true)
        let candidates = profiles.map {
            SignInRouting.Candidate(profile: $0, signedIn: ($0.isRunning && !$0.isDefault) ? SignInState.signedIn(profileDir: $0.path) : nil)
        }
        let front = WindowList.frontmost(among: Set(profiles.compactMap(\.pid)))
        // A profile that has signed in since (inside Claude's own window, which never comes
        // through here) is no longer waiting, whatever the marker says.
        let pendingIDs = pending.get().filter { id in
            store.resolve(id).map { SignInState.signedIn(profileDir: $0.path) != true } ?? false
        }
        if let pick = SignInRouting.select(candidates, pendingIDs: pendingIDs, frontmostPID: front) {
            deliver(link, to: pick.profile)
            if pendingIDs.contains(pick.profile.id) { pending.remove(pick.profile.id) }
            log("Sign-in sent to '\(pick.profile.name)' (\(pick.reason)).")
        } else {
            deliver(link, to: defaultProfile)
            log("Sign-in sent to Default (no other account was waiting for one).")
        }
    }

    // MARK: Logs

    /// An error as its domain and code only. Its message can quote the URL an operation
    /// was about, and a claude:// sign-in link carries a one-time code; logs are pasted
    /// into public bug reports.
    public static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code)"
    }

    public func log(_ message: String) {
        Switcher.append(message, to: paths.routerLog)
    }

    public func logError(_ message: String) {
        Switcher.append(message, to: paths.errorLog)
    }

    /// One queue for every log line within a process, and a file lock across the app and the command line,
    /// so lines and the rotation never race. Logging never fails an action: every failure is silent.
    private static let logQueue = DispatchQueue(label: "ClaudeProfileSwitcher.log")

    static func append(_ message: String, to file: URL) {
        logQueue.sync { appendNow(message, to: file) }
    }

    private static func appendNow(_ message: String, to file: URL) {
        let lock = URL(fileURLWithPath: file.path + ".lock")
        // A lock failure skips the line rather than risk an unlocked write.
        try? FileLock.exclusively(lock) {
            let fm = FileManager.default
            // One line per event, so this only grows large over years. Start over past 100 KB.
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 100_000 { try? fm.removeItem(at: file) }
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
            // O_APPEND with a single write keeps the line whole even if another process slipped in.
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        }
    }
}
