import Foundation

/// Reading and rewriting the per-profile worktree lease file (`git-worktrees.json`). Only
/// schema version 2 is understood; the file is never created, and unknown fields are kept.
public struct WorktreeLeases {
    public static let supportedSchema = 2

    public enum Read: Equatable {
        case missing
        case unreadable
        case unsupported(schema: Int?)
        case ok([String: Any])

        public static func == (a: Read, b: Read) -> Bool {
            switch (a, b) {
            case (.missing, .missing), (.unreadable, .unreadable): return true
            case let (.unsupported(x), .unsupported(y)): return x == y
            case let (.ok(x), .ok(y)): return NSDictionary(dictionary: x).isEqual(to: y)
            default: return false
            }
        }
    }

    public static func file(_ profile: Profile) -> URL {
        profile.path.appendingPathComponent("git-worktrees.json")
    }

    public static func read(_ profile: Profile) -> Read {
        let url = file(profile)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        guard let schema = (root["schemaVersion"] as? NSNumber)?.intValue, schema == supportedSchema else {
            return .unsupported(schema: (root["schemaVersion"] as? NSNumber)?.intValue)
        }
        return .ok(root)
    }

    private static func normalised(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func worktrees(_ root: [String: Any]) -> [String: Any] {
        (root["worktrees"] as? [String: Any]) ?? [:]
    }

    /// The session holding the lease on the worktree at `path`, if any.
    public static func holder(of path: String, in root: [String: Any]) -> String? {
        let wanted = normalised(path)
        for case let value as [String: Any] in worktrees(root).values {
            if let p = value["path"] as? String, normalised(p) == wanted {
                return value["leasedBy"] as? String
            }
        }
        return nil
    }

    /// The entry at `path` that is leased to `sessionID`.
    public static func entry(leasedTo sessionID: String, path: String, in root: [String: Any]) -> (name: String, value: [String: Any])? {
        let wanted = normalised(path)
        for (key, raw) in worktrees(root) {
            guard let value = raw as? [String: Any], let p = value["path"] as? String,
                  normalised(p) == wanted, value["leasedBy"] as? String == sessionID else { continue }
            return (name: (value["name"] as? String) ?? key, value: value)
        }
        return nil
    }

    /// A copy of `root` with `entry` leased to `sessionID` and marked adopted.
    public static func adding(_ entry: (name: String, value: [String: Any]), for sessionID: String, to root: [String: Any]) throws -> [String: Any] {
        let path = (entry.value["path"] as? String).map(normalised)
        var wts = worktrees(root)
        var stale: [String] = []
        for (key, raw) in wts {
            guard let value = raw as? [String: Any] else { continue }
            let sameName = key == entry.name || value["name"] as? String == entry.name
            let samePath = path != nil && (value["path"] as? String).map(normalised) == path
            guard sameName || samePath else { continue }
            let lease = value["leasedBy"]
            if lease == nil || lease is NSNull {
                stale.append(key)
                continue
            }
            if let holder = lease as? String, holder == sessionID { return root }
            let holder = (lease as? String) ?? "?"
            throw SwitcherError(L("The worktree \(entry.name) is already leased to another chat (\(holder)).",
                                  "\(entry.name) çalışma ağacı zaten başka bir sohbete kiralı (\(holder))."))
        }
        for key in stale { wts.removeValue(forKey: key) }
        var value = entry.value
        for k in ["leaseCleared", "pooledAt", "parkedStateKey", "uncleanSince"] { value.removeValue(forKey: k) }
        value["leasedBy"] = sessionID
        value["adopted"] = true
        wts[entry.name] = value
        var out = root
        out["worktrees"] = wts
        return out
    }

    /// A copy of `root` with the lease on `name` cleared.
    public static func releasing(name: String, from root: [String: Any]) -> [String: Any] {
        var wts = worktrees(root)
        guard var value = wts[name] as? [String: Any] else { return root }
        value["leasedBy"] = NSNull()
        value["leaseCleared"] = true
        wts[name] = value
        var out = root
        out["worktrees"] = wts
        return out
    }

    /// Writes through a symlink to the real file, after a dated backup, atomically, `0600`.
    /// Never creates the file and never writes a schema other than 2.
    public static func write(_ root: [String: Any], basedOn original: [String: Any], to profile: Profile) throws {
        let link = file(profile)
        guard FileManager.default.fileExists(atPath: link.path) else {
            throw SwitcherError(L("\(link.path) does not exist; it is never created.", "\(link.path) yok; oluşturulmaz."))
        }
        guard (root["schemaVersion"] as? NSNumber)?.intValue == supportedSchema else {
            throw SwitcherError(L("Unsupported worktree lease schema; nothing was written.", "Desteklenmeyen çalışma ağacı kira şeması; hiçbir şey yazılmadı."))
        }
        guard case .ok(let current) = read(profile) else {
            throw SwitcherError(L("\(link.path) is not a readable version 2 file; nothing was written.",
                                  "\(link.path) okunabilir bir sürüm 2 dosyası değil; hiçbir şey yazılmadı."))
        }
        guard NSDictionary(dictionary: current).isEqual(to: original) else {
            throw SwitcherError(L("Claude changed its worktree list in the meantime; nothing was written. Try again.",
                                  "Claude bu arada worktree listesini değiştirdi; hiçbir şey yazılmadı. Tekrar deneyin."))
        }
        let real = link.resolvingSymlinksInPath()
        try ChatTransfer.backUp(real)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        let temp = real.deletingLastPathComponent().appendingPathComponent(".claude-profile-switcher-\(UUID().uuidString).tmp")
        try data.write(to: temp)
        chmod(temp.path, 0o600)
        if rename(temp.path, real.path) != 0 {
            let message = String(cString: strerror(errno))
            unlink(temp.path)
            throw SwitcherError(message)
        }
    }
}
