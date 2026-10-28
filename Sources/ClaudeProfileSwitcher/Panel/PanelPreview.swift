import AppKit
import SwiftUI
import SwitcherCore

/// Renders the panel with sample accounts to PNG files, light and dark, so its design can
/// be reviewed without clicking through the real thing. The window material is drawn as
/// a flat colour here; on screen it is translucent.
enum PanelPreview {
    static func render(to dir: URL) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try renderMenuBarIcon(to: dir)
        try renderSharedChatsWindow(to: dir)
        for (scenario, makeState) in scenarios {
            for (look, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let state = makeState()
                let host = NSHostingView(rootView: PanelView(state: state))
                let size = host.fittingSize
                // A key window in an active app, so switches and buttons draw in their active colours.
                let window = StatusPanel()
                window.setFrame(NSRect(x: -4000, y: -4000, width: size.width + 40, height: size.height + 40), display: false)
                window.appearance = NSAppearance(named: name)
                let surface = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
                surface.wantsLayer = true
                surface.appearance = NSAppearance(named: name)
                // A soft desktop-like backdrop, so the screenshot reads as a panel over a desktop.
                let backdrop = CAGradientLayer()
                backdrop.frame = surface.bounds
                backdrop.colors = name == .darkAqua
                    ? [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.20, alpha: 1).cgColor, NSColor(srgbRed: 0.20, green: 0.14, blue: 0.24, alpha: 1).cgColor]
                    : [NSColor(srgbRed: 0.78, green: 0.84, blue: 0.95, alpha: 1).cgColor, NSColor(srgbRed: 0.93, green: 0.84, blue: 0.90, alpha: 1).cgColor]
                backdrop.startPoint = CGPoint(x: 0, y: 1)
                backdrop.endPoint = CGPoint(x: 1, y: 0)
                surface.layer?.addSublayer(backdrop)
                let card = NSView(frame: NSRect(x: 20, y: 20, width: size.width, height: size.height))
                card.wantsLayer = true
                card.layer?.cornerRadius = 12
                card.layer?.borderWidth = 0.5
                card.layer?.borderColor = (name == .darkAqua ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.10)).cgColor
                card.layer?.backgroundColor = (name == .darkAqua ? NSColor(white: 0.17, alpha: 0.97) : NSColor(white: 0.975, alpha: 0.97)).cgColor
                host.frame = card.bounds
                card.addSubview(host)
                surface.addSubview(card)
                window.contentView = surface
                NSApp.setActivationPolicy(.accessory)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                surface.layoutSubtreeIfNeeded()
                guard let rep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { continue }
                surface.cacheDisplay(in: surface.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(scenario)-\(look).png"))
                window.orderOut(nil)
            }
        }
    }

    /// The Shared chats window with linking on: a chat that will split, one that is behind, one linked, one broken.
    static func renderSharedChatsWindow(to dir: URL) throws {
        let model = SharedChatsModel()
        model.linkEnabled = true
        func copy(_ account: String, archived: Bool = false, lease: Bool? = false) -> ChatCopy {
            ChatCopy(profileID: account, profileName: account, record: URL(fileURLWithPath: "/r/\(account)"), cwd: "/w/app", worktreePath: "/w/app",
                     transcript: URL(fileURLWithPath: "/t/\(account)"), hasTranscript: true, isArchived: archived, lastActivity: Date(), leaseHeld: lease)
        }
        func chat(_ id: String, _ title: String, _ folder: String, linked: Bool = false, _ status: [(String, CopyStatus)]) -> SharedChat {
            SharedChat(id: id, cliSessionID: id, title: title, folder: folder, copies: status.map { copy($0.0) },
                       status: Dictionary(uniqueKeysWithValues: status), isLinked: linked)
        }
        model.chats = [
            chat("a", "Stop recurring price alerts", "sharp-liskov", [("Default", .latest), ("Work", .willSplit)]),
            chat("b", "Fix the onboarding crash", "calm-turing", [("Default", .latest), ("Work", .behind(messages: 14))]),
            chat("c", "Refactor the paywall", "kind-hopper", linked: true, [("Default", .latest), ("Work", .latest)]),
            chat("d", "Migrate the cache layer", "bold-curie", linked: true, [("Default", .latest), ("Work", .linkBroken)]),
            chat("e", "Rewrite the share sheet", "wise-knuth", linked: true, [("Default", .latest), ("Work", .archivedHereOnly)]),
        ]
        for (look, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let host = NSHostingView(rootView: SharedChatsView(model: model).frame(width: 560, height: 640).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: name)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: name)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("shared-chats-window-\(look).png"))
            window.orderOut(nil)
        }
    }

    /// The menu bar icon on a light and a dark menu bar strip, at 4x, tinted the way macOS
    /// tints a template image.
    static func renderMenuBarIcon(to dir: URL) throws {
        for (look, bar, ink) in [("light", NSColor(white: 0.93, alpha: 1), NSColor(white: 0.1, alpha: 1)),
                                 ("dark", NSColor(white: 0.16, alpha: 1), NSColor(white: 0.95, alpha: 1))] {
            let rep = Badge.render(pixels: 160) { s in
                bar.setFill(); NSRect(x: 0, y: 0, width: s, height: s).fill()
                let icon = MenuBarIcon.image(points: 18)
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r)
                    ink.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: (s - 72) / 2, y: (s - 72) / 2, width: 72, height: 72))
            }
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("menubar-\(look).png"))
        }
    }

    static let scenarios: [(String, () -> PanelState)] = [
        ("accounts", {
            let s = base()
            s.rows = [
                row(Profile.defaultID, .open, last: 0, session: 38),
                row("Work", .open, color: 0, last: 0, session: 81),
                row("Client", .waitingForSignIn, color: 3, signedIn: false, last: 0),
                row("Personal", .closed, color: 1, last: 3 * 3600, session: 100),
                row("Account 5", .opening, color: 2, last: nil),
            ]
            s.routingOn = true
            s.highlighted = "Work"
            return s
        }),
        ("usage-paused", {
            let s = base()
            s.rows = [
                row(Profile.defaultID, .open, last: 0, session: 100, measured: 16 * 3600),
                row("Work", .open, color: 0, last: 0, session: 8, measured: 7 * 3600),
                row("Personal", .closed, color: 1, last: 3 * 86400, session: 40, measured: 3 * 86400),
            ]
            s.routingOn = true
            return s
        }),
        ("shared-chats", {
            let s = base()
            s.rows = [
                row(Profile.defaultID, .open, last: 0, session: 38),
                row("Work", .closed, color: 0, last: 3600, session: 20),
            ]
            s.divergedChats = 2
            s.divergedChatIDs = ["local_a", "local_b"]
            return s
        }),
        ("link-setting", {
            let s = base()
            s.rows = [row(Profile.defaultID, .open, last: 0, session: 38), row("Work", .closed, color: 0, last: 3600, session: 20)]
            s.claudeVersion = "4.30.1"
            s.linkChats = true
            s.syncPins = true
            return s
        }),
        ("first-run", {
            let s = base()
            s.rows = [row(Profile.defaultID, .open, last: 0)]
            return s
        }),
        ("editing", {
            let s = base()
            s.rows = [
                row(Profile.defaultID, .closed, last: 26 * 3600),
                row("Account 2", .waitingForSignIn, color: 0, signedIn: false, last: 0),
                row("Personal", .closed, color: 1, last: 4 * 86400),
            ]
            s.showRoutingBanner = true
            s.renamingID = "Account 2"
            s.renameText = "Work"
            s.deletingID = "Personal"
            return s
        }),
    ]

    static func base() -> PanelState {
        let s = PanelState()
        s.claudeVersion = "3.6556.2"
        s.claudeIcon = NSWorkspace.shared.icon(forFile: "/Applications/Claude.app")
        s.claudeIcon?.size = NSSize(width: 26, height: 26)
        return s
    }

    static func row(_ id: String, _ status: AccountRow.Status, color: Int = 0, signedIn: Bool? = true, last: TimeInterval?,
                    session: Int? = nil, measured: TimeInterval = 600) -> AccountRow {
        AccountRow(id: id, name: id, isDefault: id == Profile.defaultID, status: status, signedIn: signedIn,
                   lastUsed: last.map { Date().addingTimeInterval(-$0) }, colorIndex: color, hasLauncher: false,
                   usage: session.map { PlanUsage(measuredAt: Date().addingTimeInterval(-measured), session: $0, weekly: 30) })
    }
}
