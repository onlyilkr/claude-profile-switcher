import Foundation

/// One lease entry the switcher added to, or released in, a profile's `git-worktrees.json`.
public struct LinkRecord: Codable, Equatable {
    public var profileID: String
    public var entryName: String
    /// "added" | "released"
    public var action: String
    /// The entry's JSON before the change; nil when it was added fresh.
    public var previous: Data?
    /// The entry's JSON after the change.
    public var written: Data
    public var at: Date
    public var sessionID: String

    public init(profileID: String, entryName: String, action: String, previous: Data?, written: Data, at: Date, sessionID: String) {
        self.profileID = profileID; self.entryName = entryName; self.action = action
        self.previous = previous; self.written = written; self.at = at; self.sessionID = sessionID
    }
}

/// What the switcher changed in lease files, kept in `links.json` so it can be undone.
public final class LinksLedger {
    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    private func load() -> [LinkRecord]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([LinkRecord].self, from: data)
    }

    public func records() -> [LinkRecord] {
        lock.lock(); defer { lock.unlock() }
        return load() ?? []
    }

    public func append(_ r: [LinkRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let existing = load() else { throw unreadable() }
        try save(existing + r)
    }

    public func remove(where match: (LinkRecord) -> Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard let existing = load() else { throw unreadable() }
        try save(existing.filter { !match($0) })
    }

    public func isLinked(sessionID: String) -> Bool {
        records().contains { $0.action == "added" && $0.sessionID == sessionID }
    }

    private func unreadable() -> SwitcherError {
        SwitcherError(L("\(file.path) is not readable; it was left as it is.", "\(file.path) okunamadı; olduğu gibi bırakıldı."))
    }

    /// Temp file in the same folder, 0600, renamed into place. An unreadable ledger is never
    /// overwritten (callers go through `load`).
    private func save(_ list: [LinkRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(list)
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".claude-profile-switcher-\(UUID().uuidString).tmp")
        try data.write(to: temp)
        chmod(temp.path, 0o600)
        if rename(temp.path, file.path) != 0 {
            let message = String(cString: strerror(errno))
            unlink(temp.path)
            throw SwitcherError(message)
        }
    }
}
