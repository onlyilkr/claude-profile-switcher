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

/// "This profile was launched signed out and is expecting a sign-in", for 15 minutes.
public struct PendingSignIn {
    public let file: URL

    public init(file: URL) { self.file = file }

    public func set(_ id: String, minutes: Double = 15, now: Date = Date()) {
        let marker: [String: Any] = ["Profile": id, "Expires": now.addingTimeInterval(minutes * 60).timeIntervalSince1970]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: marker) { try? data.write(to: file, options: .atomic) }
    }

    public func get(now: Date = Date()) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = marker["Profile"] as? String, let expires = marker["Expires"] as? Double,
              expires > now.timeIntervalSince1970 else { clear(); return nil }
        return id
    }

    public func clear() { try? FileManager.default.removeItem(at: file) }
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

    /// Where a sign-in goes, first rule that applies: the account launched while signed
    /// out, the only open account that is signed out, the open account whose window was
    /// used last. nil leaves it to Default.
    public static func select(_ candidates: [Candidate], pendingID: String?, frontmostPID: pid_t?) -> Decision? {
        if let pendingID, let hit = candidates.first(where: { $0.profile.id == pendingID && !$0.profile.isDefault }) {
            return Decision(profile: hit.profile, reason: "launched while signed out")
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
