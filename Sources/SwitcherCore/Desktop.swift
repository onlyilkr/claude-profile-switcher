import AppKit
import CoreGraphics
import CoreServices

/// The installed Claude desktop app.
public struct ClaudeApp {
    public static let bundleID = "com.anthropic.claudefordesktop"

    public let url: URL
    public let executable: String
    public let version: String

    /// A path given with --claude-path first, then wherever Launch Services knows Claude
    /// is, then the usual folders. `strict`: a path the user typed must be right, not
    /// quietly replaced by another Claude.
    public static func locate(override: String?, strict: Bool = false) throws -> ClaudeApp {
        var candidates: [URL] = []
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if strict {
                guard url.pathExtension == "app", Bundle(url: url)?.executableURL != nil else {
                    throw SwitcherError(L("--claude-path must point at Claude.app; '\(override)' is not an app.",
                                          "--claude-path Claude.app'i göstermeli; '\(override)' bir uygulama değil."))
                }
            }
            candidates.append(url)
        }
        if let known = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { candidates.append(known) }
        candidates.append(URL(fileURLWithPath: "/Applications/Claude.app"))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app"))

        for candidate in candidates {
            guard candidate.pathExtension == "app", let bundle = Bundle(url: candidate),
                  let exe = bundle.executableURL?.resolvingSymlinksInPath().path,
                  FileManager.default.isExecutableFile(atPath: exe) else { continue }
            let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            return ClaudeApp(url: candidate, executable: exe, version: version)
        }
        throw SwitcherError(L(
            "Could not find the Claude desktop app. Install it from claude.ai/download, or point at it once:\n    --claude-path /path/to/Claude.app",
            "Claude masaüstü uygulaması bulunamadı. claude.ai/download adresinden kurun ya da bir kez yolunu gösterin:\n    --claude-path /yol/Claude.app"))
    }
}

/// Apple Events sent to one Claude process by pid. Several copies of the same app run at
/// once, so anything addressed by bundle id or name could reach the wrong account.
/// macOS asks the user once before the switcher may send these (Automation privacy).
public enum AppleEvents {
    static let coreEventClass: FourCharCode = 0x6165_7674   // 'aevt'
    static let reopenApplication: FourCharCode = 0x7261_7070 // 'rapp'
    static let getURL: FourCharCode = 0x4755_524C           // 'GURL', class and id
    static let directObject: FourCharCode = 0x2D2D_2D2D     // '----'

    /// What a Dock click does: Claude shows its window again if it was closed.
    @discardableResult
    public static func reopen(pid: pid_t) -> Error? {
        send(event(coreEventClass, reopenApplication, pid: pid))
    }

    /// Delivers a claude:// link exactly as Launch Services would, to this copy only.
    @discardableResult
    public static func openURL(_ link: String, pid: pid_t) -> Error? {
        let e = event(getURL, getURL, pid: pid)
        e.setParam(NSAppleEventDescriptor(string: link), forKeyword: directObject)
        return send(e)
    }

    /// errAEEventNotPermitted: the user said no in Privacy & Security > Automation.
    public static func isNotPermitted(_ error: Error) -> Bool { (error as NSError).code == -1743 }

    static func event(_ eventClass: FourCharCode, _ id: FourCharCode, pid: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: eventClass, eventID: id,
                               targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                               returnID: -1,       // kAutoGenerateReturnID
                               transactionID: 0)   // kAnyTransactionID
    }

    static func send(_ event: NSAppleEventDescriptor) -> Error? {
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
            return nil
        } catch {
            return error
        }
    }
}

/// On-screen windows, front to back. Owner and layer need no Screen Recording permission.
public enum WindowList {
    static func windows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    static func isDocumentWindow(_ w: [String: Any]) -> Bool {
        guard (w[kCGWindowLayer as String] as? Int) == 0, ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
              let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return false }
        return bounds.width >= 100 && bounds.height >= 100
    }

    static func owner(_ w: [String: Any]) -> pid_t? {
        (w[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
    }

    /// The browser is in front while a sign-in completes, so the frontmost app cannot be
    /// used; the first Claude window in z-order is the account used most recently.
    public static func frontmost(among pids: Set<pid_t>) -> pid_t? {
        for w in windows() where isDocumentWindow(w) {
            if let pid = owner(w), pids.contains(pid) { return pid }
        }
        return nil
    }

    public static func hasWindow(pid: pid_t) -> Bool {
        windows().contains { isDocumentWindow($0) && owner($0) == pid }
    }
}

public enum Focus {
    /// Brings one Claude copy forward. macOS 14 only lets the active app hand activation
    /// on, so the switcher activates itself first and yields to Claude. A copy whose window
    /// was closed (Claude keeps running) gets the Dock click's reopen event.
    public static func bring(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if app.isHidden { app.unhide() }
        if let me = NSApp {
            if #available(macOS 14.0, *) {
                me.activate()
                me.yieldActivation(to: app)
            } else {
                me.activate(ignoringOtherApps: true)
            }
        }
        app.activate(options: [.activateAllWindows])
        if !WindowList.hasWindow(pid: pid) {
            DispatchQueue.global(qos: .userInitiated).async { AppleEvents.reopen(pid: pid) }
        }
    }
}

/// Which app macOS opens claude:// links with. The old Launch Services calls are the ones
/// Electron (and so Claude) uses, and unlike the NSWorkspace replacement they never put
/// up a confirmation of their own.
public enum LinkHandler {
    public static func current(scheme: String) -> String? {
        LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String?
    }

    @discardableResult
    public static func set(scheme: String, bundleID: String) -> OSStatus {
        LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
    }
}
