import Foundation

/*
    Telling the user a newer release is out. The switcher's only network request: at most once a day
    (a failed one is tried again an hour later), while "Check for updates" is on, a GET of the
    latest GitHub release of this repository. It sends no cookies, no account, chat or profile
    information, only what any HTTPS request carries plus a User-Agent naming the app's version.

    The response is not trusted: only `tag_name` is read, and only a plain `vMAJOR.MINOR.PATCH` of a
    published, non-prerelease release is accepted. Anything the switcher opens afterwards (the release
    page, or `brew upgrade` in Terminal) is built from that checked version, never from a URL in the
    response. The switcher never downloads or replaces itself.
*/

/// A release version: three numbers, as tags are written ("v1.2.0" or "1.2.0").
public struct AppVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        guard text.range(of: #"^v?[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$"#, options: .regularExpression) != nil else { return nil }
        let numbers = (text.hasPrefix("v") ? String(text.dropFirst()) : text).split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        parts = numbers
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

/// The update check's own file in the switcher's folder: when it last checked, what it found, and the
/// version whose note the user closed. Holds version numbers and a date only.
public final class UpdateState {
    private let file: URL
    public var lastCheck: Date?
    public var latest: AppVersion?
    public var dismissed: AppVersion?

    public init(file: URL) {
        self.file = file
        let raw = (try? Data(contentsOf: file)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        lastCheck = (raw["lastCheck"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        latest = (raw["latest"] as? String).flatMap(AppVersion.init)
        dismissed = (raw["dismissed"] as? String).flatMap(AppVersion.init)
    }

    public func save() {
        var raw: [String: Any] = [:]
        if let lastCheck { raw["lastCheck"] = lastCheck.timeIntervalSince1970 }
        if let latest { raw["latest"] = latest.description }
        if let dismissed { raw["dismissed"] = dismissed.description }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if (try? data.write(to: file, options: .atomic)) != nil { chmod(file.path, 0o600) }
    }

    /// The release to tell the user about: newer than `current`, and not the one whose note was closed.
    public func offer(current: String) -> AppVersion? {
        guard let newer = UpdateCheck.newer(than: current, latest: latest) else { return nil }
        return newer == dismissed ? nil : newer
    }
}

public enum UpdateCheck {
    public static let repository = "onlyilkr/claude-profile-switcher"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let cask = "claude-profile-switcher"
    public static let bundleID = "io.github.onlyilkr.ClaudeProfileSwitcher"
    static let interval: TimeInterval = 86_400

    /// The version a published, non-prerelease release response names; nil for anything else.
    public static func latest(from data: Data) -> AppVersion? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              raw["draft"] as? Bool != true, raw["prerelease"] as? Bool != true,
              let tag = raw["tag_name"] as? String else { return nil }
        return AppVersion(tag)
    }

    /// `latest` when it is newer than the running `current` version (a build without one never asks).
    public static func newer(than current: String, latest: AppVersion?) -> AppVersion? {
        guard let latest, let running = AppVersion(current), running < latest else { return nil }
        return latest
    }

    public static func releasePage(_ version: AppVersion) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
    }

    /// A day after the last successful check; also when the clock went back past it.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }

    public static func request(current: String) -> URLRequest {
        var r = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("ClaudeProfileSwitcher/\(current)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Checks when due and returns the release to offer, if any (also what an earlier check found).
    /// `fetch` performs the request and returns the body and HTTP status. Only a readable answer counts as a
    /// check: a failure leaves `lastCheck` alone, so the next attempt (an hour later) tries again.
    @discardableResult
    public static func run(state: UpdateState, current: String, now: Date = Date(),
                           fetch: (URLRequest) -> Result<(Data, Int), Error>) -> AppVersion? {
        if isDue(lastCheck: state.lastCheck, now: now),
           case .success(let (data, status)) = fetch(request(current: current)), status == 200,
           let latest = latest(from: data) {
            state.latest = latest
            state.lastCheck = now
            state.save()
        }
        return state.offer(current: current)
    }

    /// One blocking GET with an ephemeral session (no cookies, no cache, no stored credentials).
    /// For a background queue only.
    public static func fetch(_ request: URLRequest) -> Result<(Data, Int), Error> {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Data, Int), Error> = .failure(URLError(.unknown))
        session.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    // MARK: Homebrew

    public static let brewPrefixes = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]

    /// The `brew` that installed this app: a prefix with this cask in its Caskroom and an executable brew.
    public static func brew(prefixes: [URL] = brewPrefixes) -> URL? {
        let fm = FileManager.default
        for prefix in prefixes {
            let brew = prefix.appendingPathComponent("bin/brew")
            if fm.fileExists(atPath: prefix.appendingPathComponent("Caskroom/\(cask)").path), fm.isExecutableFile(atPath: brew.path) {
                return brew
            }
        }
        return nil
    }

    /// A Terminal script that upgrades the cask (Homebrew quits the app first) and opens it again.
    public static func upgradeScript(brew: URL) -> String {
        let quoted = "'" + brew.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        echo "Updating Claude Profile Switcher with Homebrew..."
        \(quoted) upgrade --cask \(cask) && open -b \(bundleID)
        """ + "\n"
    }
}
