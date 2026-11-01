import AppKit

/// "Claude - <name>.app" in ~/Applications: the macOS counterpart of the Windows desktop
/// and Start menu shortcuts. Spotlight and Launchpad find it, and it can be kept in the
/// Dock. It is a tiny script bundle that asks the switcher to open the profile, so a click
/// on an account that is already open brings it forward instead of starting a second copy.
public struct Launchers {
    /// Written into each launcher's Info.plist; only bundles carrying it are ever removed.
    public static let markerKey = "ClaudeProfileSwitcherProfile"
    public static let urlScheme = "claudeprofileswitcher"

    public let dir: URL
    public let ownBundleID: String

    public init(dir: URL, ownBundleID: String) {
        self.dir = dir
        self.ownBundleID = ownBundleID
    }

    /// A label is typed by the user or hand-edited into settings.json, so it never decides
    /// where the bundle lives: separators become dashes, control characters go, no leading dot.
    public static func fileName(forLabel label: String) -> String {
        let dropped = CharacterSet.controlCharacters.union(.newlines)
        var name = String(String.UnicodeScalarView(label.unicodeScalars.filter { !dropped.contains($0) }.map {
            $0 == "/" || $0 == ":" ? "-" : $0
        }))
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Profile" : name
    }

    public func url(forLabel label: String) -> URL {
        dir.appendingPathComponent("Claude - \(Launchers.fileName(forLabel: label)).app", isDirectory: true)
    }

    public func exists(label: String) -> Bool {
        profileID(of: url(forLabel: label)) != nil
    }

    /// The profile id a launcher opens, or nil when the bundle is not one of ours.
    public func profileID(of bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info[Launchers.markerKey] as? String
    }

    /// The readable ASCII part of the id plus a hash of all of it: "Account 2" and
    /// "Account2", or two names in another script, must not share a bundle id.
    public static func bundleIDSuffix(for id: String) -> String {
        let readable = String(id.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init).prefix(24))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a: stable across runs, unlike hashValue
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return (readable.isEmpty ? "profile" : readable) + "-" + String(hash, radix: 16)
    }

    /// Text for a shell comment: every control and line-separator character becomes a space,
    /// so nothing in a folder name can end the comment and start a command.
    public static func commentSafe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
    }

    public static func launchURL(profileID: String) -> String {
        "\(urlScheme)://launch?profile=" + (profileID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    @discardableResult
    public func create(profile: Profile, icon: (Int) -> NSBitmapImageRep, onRegisterFailure: (OSStatus) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let target = url(forLabel: profile.name)
        if fm.fileExists(atPath: target.path) {
            guard profileID(of: target) != nil else {
                throw SwitcherError(L("'\(target.path)' already exists and was not made by the switcher.",
                                      "'\(target.path)' zaten var ve switcher tarafından oluşturulmamış."))
            }
            try fm.removeItem(at: target)
        }
        let contents = target.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        // Only letters, digits and % reach the script, so the quoting cannot be broken.
        let script = """
        #!/bin/sh
        # Made by Claude Profile Switcher: opens the "\(Launchers.commentSafe(profile.id))" Claude profile.
        exec /usr/bin/open "\(Launchers.launchURL(profileID: profile.id))"

        """
        let exe = contents.appendingPathComponent("MacOS/launch")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        chmod(exe.path, 0o755)

        let info: [String: Any] = [
            "CFBundleIdentifier": "\(ownBundleID).launcher.\(Launchers.bundleIDSuffix(for: profile.id))",
            "CFBundleName": "Claude - \(profile.name)",
            "CFBundleDisplayName": "Claude - \(profile.name)",
            "CFBundleExecutable": "launch",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            // No Dock icon of its own for the split second the script runs.
            "LSUIElement": true,
            Launchers.markerKey: profile.id,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Badge.writeICNS(to: contents.appendingPathComponent("Resources/AppIcon.icns"), render: icon)
        let status = LSRegisterURL(target as CFURL, true)
        if status != noErr { onRegisterFailure(status) }
        return target
    }

    public func remove(label: String) {
        let target = url(forLabel: label)
        guard profileID(of: target) != nil else { return }
        try? FileManager.default.removeItem(at: target)
    }
}
