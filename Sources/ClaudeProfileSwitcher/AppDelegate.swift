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
        panel.onShow = { [weak self] in self?.refresh() }
        panel.onTick = { [weak self] in self?.refresh() }
        wireActions()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Claude takes claude:// back each time a copy starts. Two cheap reads per tick;
        // anything is written only when the handler was actually lost.
        routerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.switcher?.retakeRouterIfNeeded()
        }
        switcher?.retakeRouterIfNeeded()
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
            if on { sw.enableRouting() } else { _ = sw.disableRouting() }
            self?.refresh()
        }
        a.decideRouting = { [weak self] yes in
            guard let sw = self?.switcher else { return }
            if yes { sw.enableRouting() } else { sw.settings.set("SignInRouting", false) }
            self?.refresh()
        }
        a.setOtherLinks = { [weak self] id in
            self?.switcher?.settings.set("OpenLinksIn", id == Profile.defaultID ? nil : id)
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
        a.quit = { NSApp.terminate(nil) }
        a.downloadClaude = { NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!) }
        state.actions = a
    }

    private func open(_ id: String, fromURL: Bool = false) {
        guard let sw = switcher, let p = sw.store.resolve(id, status: true) else { return }
        panel.close()
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

    // MARK: Chat transfer

    private func openTransfer(_ id: String) {
        guard let sw = switcher, let source = sw.store.resolve(id) else { return }
        let sessions = sw.transfer.sessions(in: source)
        let targets = sw.store.list(status: false).filter { $0.id != source.id }
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
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] note in
            self?.windows.removeAll { $0 === note.object as? NSWindow }
            if let token { NotificationCenter.default.removeObserver(token) }
        }
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
        // Checked again right before writing: a launcher or a link may have opened the
        // account while the switcher waited for it to quit.
        if sw.store.isRunning(target) != nil || sw.isStarting(target) {
            alert(L("'\(target.name)' is open again", "'\(target.name)' yeniden açık"),
                  L("Nothing was copied. Quit it and transfer again.", "Hiçbir şey kopyalanmadı. Kapatıp aktarımı tekrar deneyin."), style: .warning)
            return
        }
        guard var store = sw.transfer.targetStore(for: target) else {
            alert(L("Not ready yet", "Henüz hazır değil"),
                  L("'\(target.name)' has not used Claude Code yet, so there is nowhere to put the chats.\n\nOpen it, sign in, visit the Code tab once, then try again.",
                    "'\(target.name)' henüz Claude Code kullanmadı, sohbetleri koyacak yer yok.\n\nAçın, giriş yapın, Code sekmesine bir kez girin ve tekrar deneyin."))
            if relaunch { sw.launch(target) }
            return
        }
        var copied = 0, there = 0, skipped: [String] = []
        var copiedSessions: [CodeSession] = []
        for s in picked {
            switch sw.transfer.copy(s, to: &store) {
            case .copied: copied += 1; copiedSessions.append(s)
            case .alreadyThere: there += 1
            case .deletedInTarget: skipped.append("\(s.title): " + L("deleted in that account", "o hesapta silinmiş"))
            case .nameConflict: skipped.append("\(s.title): " + L("a different chat has that file name", "aynı dosya adında başka bir sohbet var"))
            case .noCLISession: skipped.append("\(s.title): " + L("not a resumable chat", "devam ettirilebilir bir sohbet değil"))
            case .failed(let why): skipped.append("\(s.title): \(why)")
            }
        }
        // Pins follow the chats copied now, in the source's order. A chat that was already
        // there keeps whatever pin state the user gave it in that account.
        var pinned = 0
        do {
            let openFolders = sw.store.list(status: true).filter { $0.isRunning }.map(\.path)
            pinned = try sw.transfer.carryPins(of: copiedSessions, from: source, to: target, openFolders: openFolders)
        } catch {
            skipped.append(L("Pins were not carried over: \(error.localizedDescription)", "Pinler taşınamadı: \(error.localizedDescription)"))
        }

        var text = L("Copied \(copied) chat(s) to '\(target.name)'.", "'\(target.name)' hesabına \(copied) sohbet kopyalandı.")
        if there > 0 { text += " " + L("\(there) were already there.", "\(there) tanesi zaten oradaydı.") }
        if store.organisationCount > 1 {
            text += " " + L("That account has \(store.organisationCount) organisations; the chats went to the one it used most recently.",
                            "O hesabın \(store.organisationCount) organizasyonu var; sohbetler en son kullandığına gitti.")
        }
        if pinned > 0 { text += " " + L("\(pinned) pinned, in the same order.", "\(pinned) tanesi aynı sırayla pinlendi.") }
        if !skipped.isEmpty { text += "\n\n" + L("Skipped:", "Atlananlar:") + "\n- " + skipped.joined(separator: "\n- ") }
        text += "\n\n" + L("The chats stay in this account too. Finish a chat in one account before continuing it in the other, since both continue the same history.",
                           "Sohbetler bu hesapta da kalır. İkisi aynı geçmişi sürdürdüğü için bir sohbeti diğer hesapta sürdürmeden önce birinde bitirin.")
        if relaunch {
            alert(L("Chats copied", "Sohbetler kopyalandı"), text)
            sw.launch(target)
        } else if copied + pinned > 0, confirm(L("Chats copied", "Sohbetler kopyalandı"), text + "\n\n" + L("Open '\(target.name)' now?", "'\(target.name)' şimdi açılsın mı?"),
                                               yes: L("Open", "Aç"), no: L("Later", "Sonra")) {
            sw.launch(target)
        } else if copied + pinned == 0 {
            alert(L("Nothing copied", "Hiçbir şey kopyalanmadı"), text)
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
