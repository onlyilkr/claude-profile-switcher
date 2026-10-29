import Foundation

public enum SignInLinks {
    /// A link arrives from any web page through Launch Services, so it is untrusted. It is
    /// handed to Claude as an Apple Event, never through a shell, but still only accepted
    /// as claude:// followed by characters RFC 3986 permits, up to 2048 of them.
    public static func isSafe(_ link: String) -> Bool {
        guard !link.isEmpty, link.utf16.count <= 2048 else { return false }
        return link.range(of: #"\Aclaude://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*\z"#, options: .regularExpression) != nil
    }

    /// claude://login/... on older builds, claude://claude.ai/sso-callback?... on current
    /// ones. The boundary keeps claude://claude.ai/sso-callbackother from counting.
    public static func isSignIn(_ link: String) -> Bool {
        link.range(of: #"\Aclaude://(login/|claude\.ai/sso-callback([/?#]|\z))"#, options: .regularExpression) != nil
    }
}

public enum SignInState {
    /// true or false, or nil when there is no config.json yet. Signing out flips
    /// windowSizeWasSignedIn to false and shrinks oauth:tokenCacheV2 to a short placeholder.
    /// Only key presence and value length are looked at, never the token itself.
    public static func signedIn(profileDir: URL) -> Bool? {
        FileCache.value(profileDir.appendingPathComponent("config.json"), parse: signedIn(configData:))
    }

    public static func signedIn(configData: Data) -> Bool? {
        guard let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else { return nil }
        if let flag = json["windowSizeWasSignedIn"] as? Bool { return flag }
        if let token = json["oauth:tokenCacheV2"] as? String { return token.count > 100 }
        return false
    }

    /// The account the profile was last signed in to, used to pick its chat store.
    public static func lastAccount(profileDir: URL) -> String? {
        guard let data = try? Data(contentsOf: profileDir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["lastKnownAccountUuid"] as? String
    }
}

/// "These profiles were launched signed out and are expecting a sign-in", each for 15 minutes.
/// Several accounts can wait at once; the file is shared with the command line, so every change
/// runs under a lock. Failures are silent, like the writes before it.
public struct PendingSignIn {
    public let file: URL

    public init(file: URL) { self.file = file }

    private struct Entry { let id: String; let expires: Double }

    private var lockFile: URL { URL(fileURLWithPath: file.path + ".lock") }

    /// Oldest first. Reads the 1.1.0 single-object file as one entry.
    private func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let raw = (json["Pending"] as? [[String: Any]]) ?? [json]
        return raw.compactMap { item in
            guard let id = item["Profile"] as? String, let expires = item["Expires"] as? Double else { return nil }
            return Entry(id: id, expires: expires)
        }
    }

    private func write(_ list: [Entry]) {
        if list.isEmpty { try? FileManager.default.removeItem(at: file); return }
        let json: [String: Any] = ["Pending": list.map { ["Profile": $0.id, "Expires": $0.expires] }]
        if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: file, options: .atomic) }
    }

    public func set(_ id: String, minutes: Double = 15, now: Date = Date()) {
        try? FileLock.exclusively(lockFile) {
            var list = entries().filter { $0.expires > now.timeIntervalSince1970 && $0.id != id }
            list.append(Entry(id: id, expires: now.addingTimeInterval(minutes * 60).timeIntervalSince1970))
            write(list)
        }
    }

    /// Live ids, most recently set first. Never writes: expired entries are dropped by `set`/`remove`.
    public func get(now: Date = Date()) -> [String] {
        entries().filter { $0.expires > now.timeIntervalSince1970 }.reversed().map(\.id)
    }

    public func remove(_ id: String, now: Date = Date()) {
        try? FileLock.exclusively(lockFile) {
            write(entries().filter { $0.expires > now.timeIntervalSince1970 && $0.id != id })
        }
    }

    public func clear() { try? FileLock.exclusively(lockFile) { try FileManager.default.removeItem(at: file) } }
}

public enum SignInRouting {
    public struct Candidate {
        public let profile: Profile
        public let signedIn: Bool?
        public init(profile: Profile, signedIn: Bool?) { self.profile = profile; self.signedIn = signedIn }
    }

    public struct Decision {
        public let profile: Profile
        public let reason: String
    }

    /// Where a sign-in goes, first rule that applies: an account launched while signed out
    /// (the frontmost of several, else the most recent), the only open account that is signed
    /// out, the open account whose window was used last. nil leaves it to Default.
    public static func select(_ candidates: [Candidate], pendingIDs: [String], frontmostPID: pid_t?) -> Decision? {
        let waiting = pendingIDs.compactMap { id in candidates.first(where: { $0.profile.id == id && !$0.profile.isDefault }) }
        if waiting.count == 1 {
            return Decision(profile: waiting[0].profile, reason: "launched while signed out")
        }
        if waiting.count > 1 {
            if let frontmostPID, let hit = waiting.first(where: { $0.profile.pid == frontmostPID }) {
                return Decision(profile: hit.profile, reason: "launched while signed out, frontmost of several")
            }
            return Decision(profile: waiting[0].profile, reason: "launched while signed out, most recent of several")
        }
        let open = candidates.filter { $0.profile.isRunning && !$0.profile.isDefault }
        let signedOut = open.filter { $0.signedIn == false }
        if signedOut.count == 1 {
            return Decision(profile: signedOut[0].profile, reason: "the only open account that is signed out")
        }
        if let frontmostPID, let hit = open.first(where: { $0.profile.pid == frontmostPID }) {
            return Decision(profile: hit.profile, reason: "its window was used most recently")
        }
        return nil
    }
}
