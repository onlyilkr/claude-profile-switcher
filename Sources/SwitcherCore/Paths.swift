import Foundation

/// Where everything lives. `home` is injectable so tests (and the hidden --home flag)
/// never touch the real Claude data.
public struct Paths {
    public static let profilePrefix = "ClaudeProfile-"

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var appSupport: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }

    /// Claude's own data folder. The switcher writes into it only while Default is closed (pins and chat records), after a backup.
    public var defaultProfile: URL { appSupport.appendingPathComponent("Claude", isDirectory: true) }

    /// Extra profiles sit next to Claude's own folder, the macOS counterpart of
    /// %LOCALAPPDATA%\ClaudeProfile-<id> in the Windows version.
    public func profileDir(id: String) -> URL {
        id == Profile.defaultID ? defaultProfile : appSupport.appendingPathComponent(Paths.profilePrefix + id, isDirectory: true)
    }

    public var switcherHome: URL { appSupport.appendingPathComponent("Claude Profile Switcher", isDirectory: true) }
    public var settingsFile: URL { switcherHome.appendingPathComponent("settings.json") }
    public var routerLog: URL { switcherHome.appendingPathComponent("sign-in-router.log") }
    public var errorLog: URL { switcherHome.appendingPathComponent("switcher-error.log") }
    public var pendingSignIn: URL { switcherHome.appendingPathComponent("pending-sign-in.json") }
    public var claimsFile: URL { switcherHome.appendingPathComponent("claims.json") }

    /// Copies of an account's pin databases taken before the switcher writes them, newest five per account.
    public var pinStoreBackups: URL { switcherHome.appendingPathComponent("backups/pinstore", isDirectory: true) }

    /// Launcher apps go where Spotlight and Launchpad look, without needing admin rights.
    public var launcherDir: URL { home.appendingPathComponent("Applications", isDirectory: true) }

    /// Claude Code transcripts, shared by every account and profile.
    public var transcriptsRoot: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
}
