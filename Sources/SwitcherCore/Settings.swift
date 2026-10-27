import Foundation

/// settings.json: labels, colours and options. Read fresh on every access, because the
/// menu bar app and command line runs (launcher apps, Terminal) share the file.
public final class Settings {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func all() -> [String: Any] { parsed() ?? [:] }

    /// nil when the file is missing (nothing saved yet) or unreadable as a JSON object.
    private func parsed() -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Set when settings.json exists but is not valid JSON, typically after a hand edit.
    /// Nothing is written then, so the file is never replaced by one that lost every other key.
    public var problem: String? {
        guard FileManager.default.fileExists(atPath: file.path), parsed() == nil else { return nil }
        return L("\(file.path) is not valid JSON, so the switcher is not saving any changes. Fix the typo or move the file away.",
                 "\(file.path) geçerli bir JSON değil, bu yüzden switcher hiçbir değişikliği kaydetmiyor. Yazım hatasını düzeltin ya da dosyayı başka yere taşıyın.")
    }

    public subscript(key: String) -> Any? { all()[key] }

    /// nil removes the key.
    public func set(_ key: String, _ value: Any?) {
        if problem != nil { return }
        var bag = all()
        if let value { bag[key] = value } else { bag.removeValue(forKey: key) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: bag, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: Labels and colours

    /// Display names. A profile's folder name is its permanent id: Electron keeps absolute
    /// paths inside its data, so renaming only ever changes this label.
    public var labels: [String: String] {
        ((self["Labels"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
    }

    public func setLabel(_ id: String, _ label: String?) {
        var map = labels
        if let label, !label.isEmpty, label != id { map[id] = label } else { map.removeValue(forKey: id) }
        set("Labels", map.isEmpty ? nil : map)
    }

    public var colors: [String: Int] {
        guard let raw = self["Colors"] as? [String: Any] else { return [:] }
        return raw.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    public func forgetColor(_ id: String) {
        var map = colors
        map.removeValue(forKey: id)
        set("Colors", map.isEmpty ? nil : map)
    }

    // MARK: Options

    public var claudePath: String? { self["ClaudePath"] as? String }

    /// nil means the user was never asked.
    public var signInRouting: Bool? { self["SignInRouting"] as? Bool }

    public var openLinksIn: String? { self["OpenLinksIn"] as? String }

    /// Extra environment for one account's Claude, from "ProfileEnv": { "<id>": { "NAME": "value" } }.
    /// Names must be letters, digits and _, not starting with a digit; others are skipped.
    public func profileEnv(_ id: String) -> [String: String] {
        guard let all = self["ProfileEnv"] as? [String: Any], let vars = all[id] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (name, value) in vars where name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
            out[name] = (value as? String) ?? "\(value)"
        }
        return out
    }

    /// Extra command line flags, from "ProfileArgs": { "<id>": "--a --b" } or { "<id>": ["--a", "x y"] }.
    public func profileArgs(_ id: String) -> [String] {
        guard let all = self["ProfileArgs"] as? [String: Any], let raw = all[id] else { return [] }
        if let line = raw as? String { return Settings.splitArgs(line) }
        if let list = raw as? [Any] { return list.map { ($0 as? String) ?? "\($0)" }.filter { !$0.isEmpty } }
        return []
    }

    /// Splits a flag string on whitespace, keeping "double" or 'single' quoted parts together.
    public static func splitArgs(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken { out.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { out.append(current) }
        return out
    }
}
