import AppKit
import SwitcherCore

// One binary, two faces: with --flags it is the command line (also what launcher apps
// and scripts use), without them it is the menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
if CLI.handles(arguments) {
    exit(CLI.run(arguments))
}

// One menu bar app at a time. Launch Services already ensures that for the app it opens;
// this covers the binary being run directly with no arguments.
let me = Bundle.main.bundleIdentifier ?? CLI.appBundle.bundleIdentifier
if let me, NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0.processIdentifier != getpid() }) {
    FileHandle.standardError.write(Data("Claude Profile Switcher is already running in the menu bar.\n".utf8))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
