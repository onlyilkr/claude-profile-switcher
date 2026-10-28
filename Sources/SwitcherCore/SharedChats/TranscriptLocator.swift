import Foundation

/// Where Claude Code keeps a chat's history: `<root>/<encoded cwd>/<cliSessionId>.jsonl`.
/// The folder name is the working directory with every character that is not a letter or digit
/// turned into "-", the way Claude names its project folders (observed behaviour).
public enum TranscriptLocator {
    /// Names longer than this are cut and get a hash suffix.
    static let maxLength = 200

    public static func projectDirName(for cwd: String) -> String {
        // Work on UTF-16 units: a character outside the BMP (an emoji) gives two dashes.
        let units = cwd.precomposedStringWithCanonicalMapping.utf16.map { u -> UInt16 in
            let alnum = (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122)
            return alnum ? u : 45
        }
        let name = String(decoding: units, as: UTF16.self)
        guard units.count > maxLength else { return name }
        // 32-bit wrapping hash over the encoded units, written in base 36.
        var h: Int32 = 0
        for u in units { h = (h << 5) &- h &+ Int32(u) }
        let magnitude = UInt32(truncatingIfNeeded: h.magnitude)
        return String(decoding: units.prefix(maxLength), as: UTF16.self) + "-" + String(magnitude, radix: 36)
    }

    public static func transcript(root: URL, cwd: String, cliSessionID: String) -> URL {
        root.appendingPathComponent(projectDirName(for: cwd), isDirectory: true)
            .appendingPathComponent(cliSessionID + ".jsonl", isDirectory: false)
    }

    /// The folder next to the transcript that holds the chat's side files.
    public static func sidecar(root: URL, cwd: String, cliSessionID: String) -> URL {
        root.appendingPathComponent(projectDirName(for: cwd), isDirectory: true)
            .appendingPathComponent(cliSessionID, isDirectory: true)
    }
}
