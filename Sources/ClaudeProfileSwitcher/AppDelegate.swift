import AppKit
import ServiceManagement
import SwiftUI
import SwitcherCore

/// The menu bar app: one icon next to the clock, one panel under it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private let state = PanelState()
    private var switcher: Switcher?
    private var startupError: String?
    private var routerTimer: Timer?
    private var windows: [NSWindow] = []
    /// Accounts launched from here that have not shown up as a process yet.
    private var opening: [String: Date] = [:]
    /// Last scan for chats that live in several accounts. Scans run off the main thread, only
    /// when the panel opens, after a transfer and from the Shared chats window.
    private var sharedChats: [SharedChat] = []
    private var scanner: SharedChatScanner?
    private var scanning = false
    private var scanAgain = false
    private let sharedChatsModel = SharedChatsModel()
    private weak var sharedChatsWindow: NSWindow?
    private var openTwiceTimer: Timer?
    private var checkingOpenTwice = false
    /// Linked chats seen broken by the last scan that started while no link operation ran.
    private var brokenBefore: Set<String> = []
    private var linksLedger: LinksLedger?
    /// Chats already reported as open in two accounts; cleared once the condition goes away.
    private var warnedOpenTwice: Set<String> = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Everything before any URL arrives: when Launch Services starts the app to hand it
        // one (a launcher clicked while the switcher was not running), application(_:open:)
        // comes before applicationDidFinishLaunching.
        do { switcher = try Switcher() } catch { startupError = error.localizedDescription }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.image()
            button.toolTip = "Claude Profile Switcher"
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        panel = PanelController(state: state, button: statusItem.button)
        panel.onShow = { [weak self] in self?.refresh(); self?.scanSharedChats() }
        panel.onTick = { [weak self] in self?.refresh() }
        wireActions()
        sharedChatsModel.refresh = { [weak self] in self?.scanSharedChats() }
        sharedChatsModel.openAccount = { [weak self] id in self?.open(id, keepPanel: true) }
        sharedChatsModel.sync = { [weak self] chat in self?.syncChat(chat) }
        sharedChatsModel.link = { [weak self] chat in self?.syncChat(chat) }
        sharedChatsModel.unlink = { [weak self] chat in self?.unlink(sessionID: chat.id) }
        sharedChatsModel.linkAll = { [weak self] in self?.linkAll() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Claude takes claude:// back each time a copy starts. Two cheap reads per tick;
        // anything is written only when the handler was actually lost.
        routerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.switcher?.retakeRouterIfNeeded()
        }
        switcher?.retakeRouterIfNeeded()
        updateOpenTwiceTimer()
        if linkingOn { scanSharedChats() }
    }

    @objc private func togglePanel() { panel.toggle() }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.scheme?.lowercased() {
            case "claude":
                switcher?.handleClaudeLink(url.absoluteString)
            case Launchers.urlScheme:
                // claudeprofileswitcher://launch?profile=<id>, from launcher apps. Any web page
                // can open such a link too, so it can only ever open an existing profile.
                guard url.host == "launch",
                      let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "profile" })?.value,
                      switcher?.store.resolve(id) != nil else { continue }
                open(id, fromURL: true)
            default:
                break
            }
        }
    }

    // MARK: State

    private func refresh() {
        // Claude may have been installed since (the panel offers the download).
        if switcher == nil {
            do { switcher = try Switcher() } catch { startupError = error.localizedDescription }
        }
        guard let sw = switcher else {
            set(\.claudeMissing, startupError ?? L("Claude was not found.", "Claude bulunamadı."))
            return
        }
        set(\.claudeMissing, nil)
        if let problem = sw.settings.problem { set(\.errorMessage, problem) }
        sw.refreshClaude()
        let now = Date()
        let profiles = sw.store.list(status: true)
        let ids = profiles.map(\.id)
        let rows = profiles.map { p -> AccountRow in
            if p.isRunning || (opening[p.id].map { now.timeIntervalSince($0) > 25 } ?? false) { opening[p.id] = nil }
            let signedIn = SignInState.signedIn(profileDir: p.path)
            let status: AccountRow.Status = p.isRunning ? (signedIn == false ? .waitingForSignIn : .open)
                                                        : (opening[p.id] != nil ? .opening : .closed)
            return AccountRow(id: p.id, name: p.name, isDefault: p.isDefault, status: status, signedIn: signedIn,
                              lastUsed: p.lastUsed,
                              colorIndex: p.isDefault ? 0 : Badge.colorIndex(for: p.id, settings: sw.settings, alive: ids),
                              hasLauncher: sw.launchers.exists(label: p.name),
                              usage: PlanUsage.latest(profileDir: p.path))
        }
        // Publishing only what changed keeps a name being typed undisturbed by the refresh.
        if state.rows != rows { state.rows = rows }
        if !state.usagePaused { set(\.usageNoticeDismissed, false) }
        if state.claudeIcon == nil {
            let icon = NSWorkspace.shared.icon(forFile: sw.claude.url.path)
            icon.size = NSSize(width: 26, height: 26)
            state.claudeIcon = icon
        }
        set(\.claudeVersion, sw.claude.version)
        set(\.routingOn, sw.routingOn)
        set(\.otherLinksID, sw.otherLinkTarget()?.id ?? Profile.defaultID)
        set(\.loginItem, SMAppService.mainApp.status == .enabled)
        let linking = sw.settings["LinkWorktreeChats"] as? Bool == true
        set(\.linkChats, linking)
        set(\.syncPins, sw.settings.syncPins)
        updateOpenTwiceTimer()
        if sharedChatsModel.linkEnabled != linking { sharedChatsModel.linkEnabled = linking }
        set(\.showRoutingBanner, sw.settings.signInRouting == nil && profiles.count > 1)
    }

    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<PanelState, T>, _ value: T) {
        if state[keyPath: key] != value { state[keyPath: key] = value }
    }

    /// Errors show at the top of the panel, which opens for them if it is closed.
    private func report(_ message: String) {
        state.errorMessage = message
        if !panel.isShown { panel.show() }
    }

    // MARK: Actions

    private func wireActions() {
        var a = PanelActions()
        a.open = { [weak self] id in self?.open(id) }
        a.add = { [weak self] in self?.addAccount() }
        a.openSharedChats = { [weak self] in self?.panel.close(); self?.openSharedChats() }
        a.openUsage = { [weak self] id in self?.openUsage(id) }
        a.rename = { [weak self] id, name in
            guard let sw = self?.switcher, let p = sw.store.resolve(id) else { return nil }
            do { _ = try sw.rename(p, to: name); self?.refresh(); return nil } catch { return error.localizedDescription }
        }
        a.delete = { [weak self] id in
            guard let sw = self?.switcher, let p = sw.store.resolve(id) else { return nil }
            do { try sw.delete(p); self?.refresh(); return nil } catch { return error.localizedDescription }
        }
        a.transfer = { [weak self] id in self?.panel.close(); self?.openTransfer(id) }
        a.launcher = { [weak self] id in
            guard let self, let sw = self.switcher, let p = sw.store.resolve(id) else { return }
            do {
                let url = try sw.createLauncher(p)
                self.panel.close()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.state.errorMessage = error.localizedDescription
            }
        }
        a.reveal = { [weak self] id in
            guard let self, let p = self.switcher?.store.resolve(id) else { return }
            guard FileManager.default.fileExists(atPath: p.path.path) else {
                self.state.errorMessage = L("'\(p.name)' has no folder yet. It is made the first time the account opens.",
                                            "'\(p.name)' için henüz klasör yok. Hesap ilk açıldığında oluşturulur.")
                return
            }
            self.panel.close()
            NSWorkspace.shared.activateFileViewerSelecting([p.path])
        }
        a.setRouting = { [weak self] on in
            guard let sw = self?.switcher else { return }
            if on {
                do { try sw.enableRouting() } catch { self?.state.errorMessage = error.localizedDescription }
            } else {
                let failures = sw.disableRouting().failures
                if !failures.isEmpty { self?.state.errorMessage = failures.joined(separator: "\n") }
            }
            self?.refresh()
        }
        a.decideRouting = { [weak self] yes in
            guard let sw = self?.switcher else { return }
            if yes {
                do { try sw.enableRouting() } catch { self?.state.errorMessage = error.localizedDescription }
            } else { self?.save("SignInRouting", false) }
            self?.refresh()
        }
        a.setOtherLinks = { [weak self] id in
            self?.save("OpenLinksIn", id == Profile.defaultID ? nil : id)
            self?.refresh()
        }
        a.setLogin = { [weak self] on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self?.state.errorMessage = L("Could not change Open at login: \(error.localizedDescription). You can add the app in System Settings > General > Login Items.",
                                             "Oturum açılışı ayarı değiştirilemedi: \(error.localizedDescription). Uygulamayı Sistem Ayarları > Genel > Giriş Öğeleri'nden ekleyebilirsiniz.")
            }
            self?.refresh()
        }
        a.setLinkChats = { [weak self] on in self?.setLinkChats(on) }
        a.linkAll = { [weak self] in self?.panel.close(); self?.linkAll() }
        a.setSyncPins = { [weak self] on in
            self?.save("SyncPins", on)
            self?.refresh()
        }
        a.quit = { NSApp.terminate(nil) }
        a.downloadClaude = { NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!) }
        state.actions = a
    }

    private func open(_ id: String, fromURL: Bool = false, keepPanel: Bool = false) {
        guard let sw = switcher, let p = sw.store.resolve(id, status: true) else { return }
        if !keepPanel { panel.close() }
        if !p.isRunning { opening[p.id] = Date() }
        sw.launch(p, expectSignIn: !fromURL) { [weak self] result in
            if case .failure(let error) = result {
                self?.opening[p.id] = nil
                self?.report(L("Could not open '\(p.name)': \(error.localizedDescription)", "'\(p.name)' açılamadı: \(error.localizedDescription)"))
            }
        }
    }

    /// Claude's own usage page for one account, with live numbers and reset times. Claude
    /// routes claude://claude.ai/<path> to that path inside its window.
    private func openUsage(_ id: String) {
        guard let sw = switcher, let p = sw.store.resolve(id, status: true) else { return }
        panel.close()
        if !p.isRunning { opening[p.id] = Date() }
        sw.launch(p, link: Switcher.usageLink, expectSignIn: false) { [weak self] result in
            if case .failure(let error) = result {
                self?.opening[p.id] = nil
                self?.report(L("Could not open usage for '\(p.name)': \(error.localizedDescription)",
                               "'\(p.name)' için kullanım açılamadı: \(error.localizedDescription)"))
            }
        }
    }

    private func addAccount() {
        guard let sw = switcher else { return }
        panel.close()
        do {
            let created = try sw.addAccount { [weak self] result in
                if case .failure(let error) = result {
                    self?.report(L("Could not open the new account: \(error.localizedDescription)", "Yeni hesap açılamadı: \(error.localizedDescription)"))
                }
            }
            opening[created.id] = Date()
        } catch {
            report(L("Could not add an account: \(error.localizedDescription)", "Hesap eklenemedi: \(error.localizedDescription)"))
        }
    }

    // MARK: Shared chats

    /// Scans on a background queue and publishes on the main thread. A request that arrives
    /// during a scan runs once more afterwards, so the result is never older than the request.
    private func scanSharedChats() {
        guard let sw = switcher else { return }
        if scanning { scanAgain = true; return }
        scanning = true
        let startedBusy = sharedChatsModel.busy
        sharedChatsModel.loading = true
        let ledger = self.ledger(sw)
        let scanner = self.scanner ?? SharedChatScanner(transcriptsRoot: sw.paths.transcriptsRoot,
                                                        links: { ledger.linkMap(profiles: sw.store.list(status: false), transcriptsRoot: sw.paths.transcriptsRoot) })
        self.scanner = scanner
        let profiles = sw.store.list(status: false)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = scanner.scan(profiles)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.sharedChats = found
                let diverged = found.filter(\.diverged)
                self.set(\.divergedChats, diverged.count)
                self.set(\.divergedChatIDs, Set(diverged.map(\.id)))
                self.set(\.linkableChats, found.filter(LinkPolicy.isPlainSplit).count)
                self.sharedChatsModel.chats = found.sorted { $0.diverged && !$1.diverged }
                self.checkLinkHealth(found, startedBusy: startedBusy)
                self.checkOpenInTwoAccounts()
                if self.scanAgain { self.scanAgain = false; self.scanSharedChats() } else { self.sharedChatsModel.loading = false }
            }
        }
    }

    // MARK: Linking (experimental)

    private var linkingOn: Bool { switcher?.settings["LinkWorktreeChats"] as? Bool == true }

    /// One ledger for the whole app, so every linker shares its lock.
    private func ledger(_ sw: Switcher) -> LinksLedger {
        if let existing = linksLedger { return existing }
        let made = LinksLedger(file: sw.paths.switcherHome.appendingPathComponent("links.json"))
        linksLedger = made
        return made
    }

    private func makeLinker(_ sw: Switcher) -> ChatLinker {
        ChatLinker(paths: sw.paths, ledger: ledger(sw), openFolders: { sw.openFolders() })
    }

    /// Claude moved a linked chat again: the way linking works has changed, so linking goes off.
    /// Nothing is unlinked.
    /// Only a chat seen broken in two consecutive scans that both ran while no link operation did counts:
    /// a scan that overlaps a link sees half-written files.
    private func checkLinkHealth(_ found: [SharedChat], startedBusy: Bool) {
        guard let sw = switcher, linkingOn else { brokenBefore = []; return }
        if startedBusy || sharedChatsModel.busy { return }
        let broken = LinkPolicy.brokenIDs(found)
        let confirmed = !broken.isDisjoint(with: brokenBefore)
        brokenBefore = broken
        guard confirmed else { return }
        brokenBefore = []
        save("LinkWorktreeChats", false)
        refresh()
        let v = sw.claude.version
        report(L("Claude moved a linked chat again (Claude \(v)); linking is off.", "Claude bağlı bir sohbeti yine taşıdı (Claude \(v)); bağlama kapatıldı."))
    }

    /// A linked chat run in two accounts at once branches its history. Only the process list is read,
    /// and only while the setting is on.
    private func updateOpenTwiceTimer() {
        if linkingOn, openTwiceTimer == nil {
            openTwiceTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.checkOpenInTwoAccounts() }
        } else if !linkingOn, let timer = openTwiceTimer {
            timer.invalidate(); openTwiceTimer = nil
        }
    }

    private func checkOpenInTwoAccounts() {
        let linked = sharedChats.filter(\.isLinked)
        guard linkingOn, !linked.isEmpty else { warnedOpenTwice = []; return }
        if checkingOpenTwice { return }
        checkingOpenTwice = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bad = LinkPolicy.openInSeveral(linked, live: ProcessScanner.liveCLISessions())
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingOpenTwice = false
                let fresh = bad.filter { !self.warnedOpenTwice.contains($0.id) }
                self.warnedOpenTwice = Set(bad.map(\.id))
                if !fresh.isEmpty {
                    self.report(fresh.map {
                        L("'\($0.title)' is open in two accounts at once; stop it in one, or its history will branch.",
                          "'\($0.title)' iki hesapta aynı anda açık; birinde durdurun, yoksa geçmişi dallanır.")
                    }.joined(separator: "\n"))
                }
            }
        }
    }

    /// Settings writes can fail (invalid file, read-only folder); say so instead of pretending.
    private func save(_ key: String, _ value: Any?) {
        do { try switcher?.settings.set(key, value) } catch {
            state.errorMessage = L("Could not save settings: \(error.localizedDescription)", "Ayarlar kaydedilemedi: \(error.localizedDescription)")
        }
    }

    private func setLinkChats(_ on: Bool) {
        guard let sw = switcher else { return }
        brokenBefore = []
        if on {
            save("LinkWorktreeChats", true)
            refresh()
            scanSharedChats()
            return
        }
        save("LinkWorktreeChats", false)
        refresh()
        warnedOpenTwice = []
        guard !ledger(sw).linkedSessionIDs().isEmpty else { return }
        panel.close()
        let pick = choose(L("Remove existing links too?", "Mevcut bağlantılar da kaldırılsın mı?"),
                          L("Linked chats keep sharing one folder and history until their links are removed. Removing needs the accounts closed; open ones are skipped.",
                            "Bağlı sohbetler, bağlantıları kaldırılana kadar tek klasör ve geçmişi paylaşmaya devam eder. Kaldırmak için hesapların kapalı olması gerekir; açık olanlar atlanır."),
                          buttons: [L("Keep links", "Bırak"), L("Remove links", "Bağlantıları kaldır")])
        if pick == 1 { unlink(sessionID: nil) }
    }

    /// Removes the links of one chat, or of all of them (nil), off the main thread.
    private func unlink(sessionID: String?) {
        guard let sw = switcher else { return }
        if sharedChatsModel.busy { reportBusy(); return }
        sharedChatsModel.busy = true
        let linker = makeLinker(sw)
        let profiles = sw.store.list(status: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = linker.unlink(sessionID: sessionID, profiles: profiles)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sharedChatsModel.busy = false
                self.scanSharedChats()
                if !result.skipped.isEmpty {
                    self.report(L("Some links were not removed:", "Bazı bağlantılar kaldırılamadı:") + "\n- " + result.skipped.joined(separator: "\n- "))
                }
            }
        }
    }

    private func syncChat(_ chat: SharedChat) {
        var winner = LinkPolicy.winner(of: chat)
        if LinkPolicy.isForked(chat) {
            let choices = LinkPolicy.forkChoices(chat)
            let pick = choose(L("Keep which copy? The other one is backed up.", "Hangi kopya kalsın? Öbürü yedeklenir."), chat.title,
                              buttons: choices.map(\.profileName) + [L("Cancel", "Vazgeç")])
            guard pick < choices.count else { return }
            winner = choices[pick].profileID
        }
        guard let winner else {
            report(L("No up-to-date copy to keep; nothing was changed.", "Tutulacak güncel kopya yok; hiçbir şey değiştirilmedi."))
            return
        }
        runLinks([(chat, winner)])
    }

    private func reportBusy() {
        report(L("Another link operation is running; try again in a moment.", "Başka bir bağlama işlemi sürüyor; birazdan tekrar deneyin."))
    }

    private func linkAll() {
        let jobs = sharedChats.filter(LinkPolicy.isPlainSplit).compactMap { chat in LinkPolicy.winner(of: chat).map { (chat, $0) } }
        guard !jobs.isEmpty else {
            report(L("No chat needs linking right now.", "Şu an bağlanması gereken sohbet yok."))
            scanSharedChats()
            return
        }
        let n = jobs.count
        runLinks(jobs, ask: L((n == 1 ? "Link 1 chat?" : "Link \(n) chats?") + " In the other account, each chat's record is replaced, its own worktree is released to Claude, and its own history may be moved to the backups. Unlink does not bring these back.",
                              "\(n) sohbet bağlansın mı? Öbür hesapta her sohbetin kaydı değiştirilir, kendi worktree'si Claude'a bırakılır ve kendi geçmişi yedeklere taşınabilir. Bağlantıyı kaldırmak bunları geri getirmez."))
    }

    /// Closes the accounts that must be closed, links off the main thread, rescans, says what happened
    /// and opens again what it closed. The winner may stay open; its chat process must not be running
    /// (the linker refuses and says so).
    /// `ask`: a question to confirm first; it joins the quit confirmation when there is one.
    private func runLinks(_ jobs: [(chat: SharedChat, winner: String)], ask: String? = nil) {
        guard let sw = switcher else { return }
        if sharedChatsModel.busy { reportBusy(); return }
        let profiles = sw.store.list(status: true)
        // A forked copy the user chose to replace is only replaced while it still has the messages the scan showed.
        var forkCounts: [String: [String: Int]] = [:]
        for job in jobs { forkCounts[job.chat.id] = LinkPolicy.expectedForks(job.chat, winner: job.winner) }
        var toQuit: [Profile] = []
        for job in jobs {
            for copy in job.chat.copies {
                guard let p = profiles.first(where: { $0.id == copy.profileID }), p.isRunning || sw.isStarting(p) else { continue }
                if (copy.profileID != job.winner || copy.leaseHeld != true), !toQuit.contains(where: { $0.id == p.id }) { toQuit.append(p) }
            }
        }
        if let starting = toQuit.first(where: { sw.isStarting($0) }) {
            alert(L("'\(starting.name)' is starting", "'\(starting.name)' açılıyor"),
                  L("Wait until its window is up, then try again.", "Penceresi açılana kadar bekleyin, sonra tekrar deneyin."), style: .warning)
            return
        }
        if !toQuit.isEmpty {
            let names = toQuit.map(\.name).joined(separator: ", ")
            let quit = L("'\(names)' must be closed to sync. Quit, sync, and open again?", "Eşitlemek için '\(names)' kapalı olmalı. Kapatılıp eşitlensin ve yeniden açılsın mı?")
            guard confirm(L("Quit and sync", "Kapat ve eşitle"), [ask, quit].compactMap { $0 }.joined(separator: "\n\n"),
                          yes: L("Quit and sync", "Kapat ve eşitle"), no: L("Cancel", "Vazgeç")) else { return }
        } else if let ask {
            guard confirm(L("Link all", "Tümünü bağla"), ask, yes: L("Link", "Bağla"), no: L("Cancel", "Vazgeç")) else { return }
        }
        sharedChatsModel.busy = true
        quitAll(toQuit, quitSoFar: []) { [weak self] quitOK, closed in
            guard let self else { return }
            guard quitOK else {
                self.sharedChatsModel.busy = false
                closed.forEach { sw.launch($0) }
                self.alert(L("'\(toQuit.first { sw.store.isRunning($0) != nil }?.name ?? "")' is still open", "'\(toQuit.first { sw.store.isRunning($0) != nil }?.name ?? "")' hâlâ açık"),
                           L("Quit it from its Claude menu, then try again.", "Claude menüsünden çıkın, sonra tekrar deneyin."), style: .warning)
                return
            }
            let linker = self.makeLinker(sw)
            let all = sw.store.list(status: false)
            DispatchQueue.global(qos: .userInitiated).async {
                var results: [(SharedChat, Result<LinkReport, Error>)] = []
                for job in jobs {
                    do { results.append((job.chat, .success(try linker.link(job.chat, winner: job.winner, profiles: all, expectedForks: forkCounts[job.chat.id] ?? [:])))) }
                    catch { results.append((job.chat, .failure(error))) }
                }
                DispatchQueue.main.async {
                    self.sharedChatsModel.busy = false
                    self.scanSharedChats()
                    var problems: [String] = [], done: [SharedChat] = []
                    for (chat, result) in results {
                        switch result {
                        case .failure(let error): problems.append("\(chat.title): \(error.localizedDescription)")
                        case .success(let report):
                            if !report.linked.isEmpty { done.append(chat) }
                            for (id, note) in report.warnings.sorted(by: { $0.key < $1.key }) {
                                problems.append("\(chat.title) (\(all.first { $0.id == id }?.name ?? id)): \(note)")
                            }
                            for (id, why) in report.skipped.sorted(by: { $0.key < $1.key }) {
                                problems.append("\(chat.title) (\(all.first { $0.id == id }?.name ?? id)): \(why)")
                            }
                        }
                    }
                    closed.forEach { sw.launch($0) }
                    if !problems.isEmpty { self.report(problems.joined(separator: "\n")) }
                    if done.count == 1 {
                        self.alert(L("Linked", "Bağlandı"),
                                   L("Linked. Both accounts now use one folder and one history for '\(done[0].title)'.",
                                     "Bağlandı. '\(done[0].title)' için iki hesap artık tek klasör ve tek geçmiş kullanıyor."))
                    } else if done.count > 1 {
                        self.alert(L("Linked", "Bağlandı"),
                                   L("Linked \(done.count) chats. Their accounts now use one folder and one history each.",
                                     "\(done.count) sohbet bağlandı. Hesaplar artık her sohbet için tek klasör ve tek geçmiş kullanıyor."))
                    }
                }
            }
        }
    }

    /// Quits the accounts one after another; the callback gets whether all went (and which were closed).
    private func quitAll(_ list: [Profile], quitSoFar: [Profile], done: @escaping (Bool, [Profile]) -> Void) {
        guard let sw = switcher, let next = list.first else { done(true, quitSoFar); return }
        sw.quit(next) { [weak self] ok in
            guard ok else { done(false, quitSoFar); return }
            self?.quitAll(Array(list.dropFirst()), quitSoFar: quitSoFar + [next], done: done)
        }
    }

    /// Forgets a window when it closes and removes its own observer. The token lives in a box, so the
    /// closure can remove it without capturing a variable that is assigned afterwards.
    private func observeClose(of window: NSWindow) {
        final class TokenBox { var token: NSObjectProtocol? }
        let box = TokenBox()
        box.token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, box] note in
            self?.windows.removeAll { $0 === note.object as? NSWindow }
            if let token = box.token { NotificationCenter.default.removeObserver(token); box.token = nil }
        }
    }

    private func openSharedChats() {
        scanSharedChats()
        if let window = sharedChatsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SharedChatsView(model: sharedChatsModel)))
        window.title = L("Shared chats", "Ortak sohbetler")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        sharedChatsWindow = window
        windows.append(window)
        observeClose(of: window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Chat transfer

    private func openTransfer(_ id: String) {
        guard let sw = switcher, let source = sw.store.resolve(id) else { return }
        // Listing a large history reads every chat record, so it stays off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sessions = sw.transfer.sessions(in: source)
            let targets = sw.store.list(status: false).filter { $0.id != source.id }
            DispatchQueue.main.async { self?.showTransfer(sw, source: source, sessions: sessions, targets: targets) }
        }
    }

    private func showTransfer(_ sw: Switcher, source: Profile, sessions: [CodeSession], targets: [Profile]) {
        if sessions.isEmpty {
            report(L("'\(source.name)' has no Claude Code chats to transfer.", "'\(source.name)' hesabında aktarılacak Claude Code sohbeti yok."))
            return
        }
        if targets.isEmpty {
            report(L("Add a second account first, then transfer chats to it.", "Önce ikinci bir hesap ekleyin, sonra sohbetleri ona aktarın."))
            return
        }
        // Weak, so the window and the view's closures do not keep each other alive.
        final class WindowRef { weak var window: NSWindow? }
        let ref = WindowRef()
        let view = TransferView(sourceName: source.name, sessions: sessions, targets: targets,
                                onCancel: { ref.window?.close() },
                                onCopy: { [weak self] picked, target in
                                    ref.window?.close()
                                    self?.startTransfer(picked, from: source, to: target)
                                })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        ref.window = window
        window.title = L("Transfer Claude Code chats", "Claude Code sohbetlerini aktar")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        windows.append(window)
        observeClose(of: window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func startTransfer(_ picked: [CodeSession], from source: Profile, to target: Profile) {
        guard let sw = switcher, !picked.isEmpty else { return }
        if sw.isStarting(target) {
            alert(L("'\(target.name)' is starting", "'\(target.name)' açılıyor"),
                  L("Wait until its window is up, then transfer again.", "Penceresi açılana kadar bekleyin, sonra aktarımı tekrar deneyin."), style: .warning)
            return
        }
        // A chat that runs in a git worktree is copied as a separate chat: Claude puts it in a
        // new worktree of the other account. Said before anything is written.
        if sw.settings["LinkWorktreeChats"] as? Bool != true, picked.contains(where: { $0.worktreePath != nil }) {
            guard confirm(L("Some of these chats use a git worktree", "Bu sohbetlerden bazıları git worktree kullanıyor"),
                          L("In '\(target.name)' a worktree chat is taken into a new worktree and continues as a separate copy; files that are not committed yet are not moved. Do not continue the same chat in both accounts.",
                            "'\(target.name)' hesabında worktree'li sohbet yeni bir worktree'ye alınır ve ayrı bir kopya olarak sürer; henüz commit edilmemiş dosyalar taşınmaz. Aynı sohbeti iki hesapta birden sürdürmeyin."),
                          yes: L("Copy anyway", "Yine de kopyala"), no: L("Cancel", "Vazgeç")) else { return }
        }
        guard sw.store.isRunning(target) != nil else { copy(picked, from: source, to: target, relaunch: false); return }
        // Claude keeps its chat list and pins in memory and writes them back when it quits,
        // which would drop anything copied under it.
        guard confirm(L("'\(target.name)' is open", "'\(target.name)' açık"),
                      L("Claude writes its chat list and pins back when it quits, which would drop chats copied while it runs. Quit '\(target.name)', copy, and open it again?",
                        "Claude çıkarken sohbet listesini ve pinleri geri yazar; açıkken kopyalananlar kaybolur. '\(target.name)' kapatılıp kopyalansın ve yeniden açılsın mı?"),
                      yes: L("Quit and copy", "Kapat ve kopyala"), no: L("Cancel", "Vazgeç")) else { return }
        sw.quit(target) { [weak self] ok in
            if ok {
                self?.copy(picked, from: source, to: target, relaunch: true)
            } else {
                self?.alert(L("'\(target.name)' is still open", "'\(target.name)' hâlâ açık"),
                            L("Quit it from its Claude menu, then transfer again.", "Claude menüsünden çıkın, sonra aktarımı tekrar deneyin."), style: .warning)
            }
        }
    }

    private func copy(_ picked: [CodeSession], from source: Profile, to target: Profile, relaunch: Bool) {
        guard let sw = switcher else { return }
        // The copy runs off the main thread, so nothing else keeps the account closed meanwhile: the
        // writing claim refuses every launch of it (and is refused itself when it is open again, e.g.
        // a launcher or a link opened it while the switcher waited for it to quit). It is dropped
        // before anything below runs on main, so the relaunch is not refused as "being updated".
        struct Outcome {
            var store: TargetStore?
            var copied = 0, there = 0, pinned = 0
            var skipped: [String] = []
            var copiedSessions: [CodeSession] = []
            var thereSessions: [CodeSession] = []
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Outcome
            do {
                outcome = try sw.whileWriting([target]) {
                    var o = Outcome()
                    guard var store = sw.transfer.targetStore(for: target) else { return o }
                    for s in picked {
                        switch sw.transfer.copy(s, to: &store) {
                        case .copied: o.copied += 1; o.copiedSessions.append(s)
                        case .alreadyThere: o.there += 1; o.thereSessions.append(s)
                        case .deletedInTarget: o.skipped.append("\(s.title): " + L("deleted in that account", "o hesapta silinmiş"))
                        case .nameConflict: o.skipped.append("\(s.title): " + L("a different chat has that file name", "aynı dosya adında başka bir sohbet var"))
                        case .noCLISession: o.skipped.append("\(s.title): " + L("not a resumable chat", "devam ettirilebilir bir sohbet değil"))
                        case .failed(let why): o.skipped.append("\(s.title): \(why)")
                        }
                    }
                    // Pins follow the chats copied now, in the source's order. A chat that was already
                    // there is left alone here; pin sync may change it when the target opens.
                    do {
                        // Starting accounts count as open, as they do for the linker.
                        o.pinned = try sw.transfer.carryPins(of: o.copiedSessions, from: source, to: target, openFolders: sw.openFolders())
                    } catch {
                        o.skipped.append(L("Pins were not carried over: \(error.localizedDescription)", "Pinler taşınamadı: \(error.localizedDescription)"))
                    }
                    o.store = store
                    return o
                }
            } catch {
                DispatchQueue.main.async {
                    self?.alert(L("'\(target.name)' is open again", "'\(target.name)' yeniden açık"),
                                L("Nothing was copied. Quit it and transfer again.", "Hiçbir şey kopyalanmadı. Kapatıp aktarımı tekrar deneyin.") + "\n" + error.localizedDescription, style: .warning)
                }
                return
            }
            DispatchQueue.main.async { self?.continueCopy(outcome.store, source: source, target: target, relaunch: relaunch,
                                                          copied: outcome.copied, there: outcome.there, pinned: outcome.pinned, skipped: outcome.skipped,
                                                          copiedSessions: outcome.copiedSessions, thereSessions: outcome.thereSessions) }
        }
    }

    /// Back on the main thread once the claim is dropped: reports, binds and rescans.
    private func continueCopy(_ storeIfReady: TargetStore?, source: Profile, target: Profile, relaunch: Bool, copied: Int, there: Int, pinned: Int,
                              skipped: [String], copiedSessions: [CodeSession], thereSessions: [CodeSession]) {
        guard let sw = switcher else { return }
        guard let store = storeIfReady else {
            alert(L("Not ready yet", "Henüz hazır değil"),
                  L("'\(target.name)' has not used Claude Code yet, so there is nowhere to put the chats.\n\nOpen it, sign in, visit the Code tab once, then try again.",
                    "'\(target.name)' henüz Claude Code kullanmadı, sohbetleri koyacak yer yok.\n\nAçın, giriş yapın, Code sekmesine bir kez girin ve tekrar deneyin."))
            if relaunch { sw.launch(target) }
            return
        }
        if copied > 0 { scanSharedChats() }

        guard !thereSessions.isEmpty else {
            // Only chats copied just now are bound: their record is the same, so the folders match.
            bindThen(copiedSessions, from: source, to: target) { links in
                self.finishCopy(copied: copied, there: there, notes: [], links: links, skipped: skipped, pinned: pinned, store: store, target: target, relaunch: relaunch)
            }
            return
        }
        // The chats that were already there may be behind or diverged; a scan of just these two
        // accounts says which. It can take about a second, so it runs off the main thread.
        let ids = Set(thereSessions.map { "local_" + $0.sessionID })
        let profiles = [source, target]
        let root = sw.paths.transcriptsRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = SharedChatScanner(transcriptsRoot: root).scan(profiles).filter { ids.contains($0.id) }
            DispatchQueue.main.async {
                guard let self else { return }
                var notes: [String] = [], plain = 0, split: [CodeSession] = []
                for s in thereSessions {
                    let chat = found.first { $0.id == "local_" + s.sessionID }
                    switch chat?.status[target.id] {
                    case .behind(let n):
                        notes.append(L("\(s.title): already in '\(target.name)', but \(SharedChatsText.behind(n)) — don't continue it there",
                                       "\(s.title): '\(target.name)' hesabında zaten var ama \(SharedChatsText.behind(n)); orada devam etmeyin"))
                    case .forked(let n):
                        notes.append(L("\(s.title): already in '\(target.name)', but it has diverged (\(SharedChatsText.ownMessages(n))) — don't continue it there",
                                       "\(s.title): '\(target.name)' hesabında zaten var ama ayrışmış (\(SharedChatsText.ownMessages(n))) — orada devam etmeyin"))
                    case .willSplit:
                        split.append(s)
                        notes.append(L("\(s.title): already in '\(target.name)', same history, but it will split when continued there",
                                       "\(s.title): '\(target.name)' hesabında zaten var, geçmiş aynı ama orada sürdürülünce ayrışacak"))
                    default: plain += 1
                    }
                }
                // Already-there chats are bound only when they share the history and would just split; the
                // behind or diverged ones go through Sync.
                self.bindThen(copiedSessions + split, from: source, to: target) { links in
                    self.finishCopy(copied: copied, there: plain, notes: notes, links: links, skipped: skipped, pinned: pinned, store: store, target: target, relaunch: relaunch)
                }
            }
        }
    }

    /// With linking on, leases each worktree chat's worktree to it in the target (closed here), off the main
    /// thread and under `busy`; then rescans and hands the result lines on.
    private func bindThen(_ sessions: [CodeSession], from source: Profile, to target: Profile, then finish: @escaping ([String]) -> Void) {
        guard let sw = switcher, linkingOn, sessions.contains(where: { $0.worktreePath != nil }) else { finish([]); return }
        if sharedChatsModel.busy {
            // Another link operation owns `busy` and the files; binding now could overlap it. Nothing is bound.
            let why = L("Another link operation is running; try again in a moment.", "Başka bir bağlama işlemi sürüyor; birazdan tekrar deneyin.")
            finish(sessions.filter { $0.worktreePath != nil }.map { L("\($0.title): not linked — \(why)", "\($0.title): bağlanmadı — \(why)") })
            return
        }
        sharedChatsModel.busy = true
        let linker = makeLinker(sw)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lines: [String] = []
            for s in sessions where s.worktreePath != nil {
                if let why = linker.bindOnTransfer(session: s, from: source, to: target) {
                    lines.append(L("\(s.title): not linked — \(why)", "\(s.title): bağlanmadı — \(why)"))
                } else {
                    lines.append(L("\(s.title): linked", "\(s.title): bağlandı"))
                }
            }
            DispatchQueue.main.async {
                self?.sharedChatsModel.busy = false
                self?.scanSharedChats()
                finish(lines)
            }
        }
    }

    private func finishCopy(copied: Int, there: Int, notes: [String], links: [String], skipped: [String], pinned: Int, store: TargetStore, target: Profile, relaunch: Bool) {
        guard let sw = switcher else { return }
        var text = L("Copied \(copied) chat(s) to '\(target.name)'.", "'\(target.name)' hesabına \(copied) sohbet kopyalandı.")
        if there > 0 { text += " " + L("\(there) were already there.", "\(there) tanesi zaten oradaydı.") }
        if store.organisationCount > 1 {
            text += " " + L("That account has \(store.organisationCount) organisations; the chats went to the one it used most recently.",
                            "O hesabın \(store.organisationCount) organizasyonu var; sohbetler en son kullandığına gitti.")
        }
        if pinned > 0 { text += " " + L("\(pinned) pinned, in the same order.", "\(pinned) tanesi aynı sırayla pinlendi.") }
        if !notes.isEmpty { text += "\n\n- " + notes.joined(separator: "\n- ") }
        if !links.isEmpty { text += "\n\n- " + links.joined(separator: "\n- ") }
        if !skipped.isEmpty { text += "\n\n" + L("Skipped:", "Atlananlar:") + "\n- " + skipped.joined(separator: "\n- ") }
        text += "\n\n" + L("The chats stay in this account too. Chats without a worktree share the same history, so finish one in one account before continuing it in the other. For worktree chats, see the Shared chats window.",
                           "Sohbetler bu hesapta da kalır. Worktree'siz sohbetler aynı geçmişi paylaşır; birini diğer hesapta sürdürmeden önce birinde bitirin. Worktree'li sohbetler için Ortak sohbetler penceresine bakın.")
        let showButton = notes.isEmpty ? nil : L("Show shared chats", "Ortak sohbetleri göster")
        if relaunch {
            if choose(L("Chats copied", "Sohbetler kopyalandı"), text, buttons: [L("OK", "Tamam")] + [showButton].compactMap { $0 }) == 1 { openSharedChats() }
            sw.launch(target)
        } else if copied + pinned > 0 {
            let pick = choose(L("Chats copied", "Sohbetler kopyalandı"), text + "\n\n" + L("Open '\(target.name)' now?", "'\(target.name)' şimdi açılsın mı?"),
                              buttons: [L("Open", "Aç"), L("Later", "Sonra")] + [showButton].compactMap { $0 })
            if pick == 0 { sw.launch(target) } else if pick == 2 { openSharedChats() }
        } else {
            if choose(L("Nothing copied", "Hiçbir şey kopyalanmadı"), text, buttons: [L("OK", "Tamam")] + [showButton].compactMap { $0 }) == 1 { openSharedChats() }
        }
    }

    // MARK: Dialogs (transfer only; everything else happens in the panel)

    private func alert(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Shows an alert with these buttons; returns the index of the one pressed.
    private func choose(_ title: String, _ text: String, buttons: [String]) -> Int {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    private func confirm(_ title: String, _ text: String, yes: String, no: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: yes)
        a.addButton(withTitle: no)
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
}
