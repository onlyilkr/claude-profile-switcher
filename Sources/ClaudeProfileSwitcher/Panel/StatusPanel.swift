import AppKit
import Combine
import SwiftUI

/// A borderless panel that hangs under the menu bar icon, the way Control Center and
/// Wi-Fi do: no arrow, the menu material, and gone as soon as you click elsewhere. It can
/// take keyboard focus (for renaming) without activating the app.
final class StatusPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject, NSWindowDelegate {
    let state: PanelState
    var onShow: () -> Void = {}
    var onTick: () -> Void = {}

    private let panel = StatusPanel()
    private let hosting: NSHostingView<PanelView>
    private weak var button: NSStatusBarButton?
    private var top: CGFloat = 0
    private var sizeWatch: AnyCancellable?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var closedAt = Date.distantPast

    init(state: PanelState, button: NSStatusBarButton?) {
        self.state = state
        self.button = button
        hosting = NSHostingView(rootView: PanelView(state: state))
        super.init()

        let surface = NSVisualEffectView()
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.maskImage = PanelController.roundedMask(radius: 12)
        hosting.autoresizingMask = [.width, .height]
        surface.addSubview(hosting)
        panel.contentView = surface
        panel.delegate = self

        // Renaming, a confirmation or a banner changes the height; the top edge stays put.
        sizeWatch = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }
    }

    var isShown: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { close(); return }
        // The click that closed the panel by taking focus away also lands on the icon.
        if Date().timeIntervalSince(closedAt) < 0.3 { return }
        show()
    }

    func show() {
        onShow()
        state.highlighted = nil
        anchorUnderButton()
        fit()
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.onTick() }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        closedAt = Date()
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        state.cancelEditing()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func anchorUnderButton() {
        guard let button, let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        top = rect.minY - 4
        panel.setFrameTopLeftPoint(NSPoint(x: rect.midX - 160, y: top))
    }

    private func fit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var x = panel.frame.minX
        if let button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            x = rect.midX - size.width / 2
            if let screen = window.screen ?? NSScreen.main {
                x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            }
        }
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    private func installMonitors() {
        // A click in another app closes the panel, as a menu would.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.close() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }) {
            monitors.append(m)
        }
    }

    /// Menu keys. While a name is being typed the text field gets everything.
    private func handleKey(_ event: NSEvent) -> Bool {
        if panel.firstResponder is NSTextView { return false }
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        switch (event.keyCode, command, event.charactersIgnoringModifiers) {
        case (125, false, _): state.moveHighlight(1); return true          // down
        case (126, false, _): state.moveHighlight(-1); return true         // up
        case (36, false, _), (76, false, _):                                           // return, enter
            // While a delete waits for its confirmation, Return must not open the account.
            if state.deletingID == nil { state.activateHighlight() }
            return true
        case (53, false, _):                                                // escape
            if state.deletingID != nil { state.cancelEditing() } else { close() }
            return true
        case (_, true, "n"?): state.actions.add(); return true
        case (_, true, "q"?): state.actions.quit(); return true
        default: return false
        }
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
