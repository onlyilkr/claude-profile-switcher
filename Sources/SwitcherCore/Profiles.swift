import Foundation

public struct Profile: Equatable {
    public static let defaultID = "Default"

    /// The folder name after the prefix, permanent.
    public let id: String
    /// What the user sees; rename changes only this.
    public let name: String
    public let path: URL
    public var pid: pid_t?
    public var lastUsed: Date?

    public init(id: String, name: String, path: URL, pid: pid_t? = nil, lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.pid = pid
        self.lastUsed = lastUsed
    }

    public var isDefault: Bool { id == Profile.defaultID }
    public var isRunning: Bool { pid != nil }
}

public final class ProfileStore {
    public let paths: Paths
    public let settings: Settings
    /// Open Claude instances keyed by `ProfileStore.key(dataFolder)`. Replaced in tests.
    public var runningMap: () -> [String: pid_t]
    /// How a deleted profile's folder goes away. The Trash by default, so a slip can be undone.
    public var remove: (URL) throws -> Void = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    public init(paths: Paths, settings: Settings, runningMap: @escaping () -> [String: pid_t]) {
        self.paths = paths
        self.settings = settings
        self.runningMap = runningMap
    }

    /// One key per folder, whatever way its path was written: the volume and file number
    /// when the folder exists (APFS ignores case by default, so "Work" and "work" are one
    /// folder), otherwise the normalised path.
    public static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var info = stat()
        if stat(path, &info) == 0 { return "inode:\(info.st_dev):\(info.st_ino)" }
        return "path:" + path.lowercased()
    }

    public static func runningMap(bundleID: String, defaultFolder: URL) -> [String: pid_t] {
        var map: [String: pid_t] = [:]
        for instance in ProcessScanner.claudeInstances(bundleID: bundleID) {
            let folder = instance.dataDir.map { URL(fileURLWithPath: $0) } ?? defaultFolder
            let k = key(folder)
            if let existing = map[k], existing < instance.pid { continue }
            map[k] = instance.pid
        }
        return map
    }

    public func ids() -> [String] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: paths.appSupport, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        let extra = items.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard name.hasPrefix(Paths.profilePrefix), name.count > Paths.profilePrefix.count else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
            let id = String(name.dropFirst(Paths.profilePrefix.count))
            return id.caseInsensitiveCompare(Profile.defaultID) == .orderedSame ? nil : id
        }
        return [Profile.defaultID] + extra.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func list(status: Bool = true) -> [Profile] {
        let running = status ? runningMap() : [:]
        let labels = settings.labels
        return ids().map { id in
            let path = paths.profileDir(id: id)
            return Profile(id: id, name: labels[id] ?? id, path: path,
                           pid: running[ProfileStore.key(path)],
                           lastUsed: status ? ProfileStore.lastUsed(path) : nil)
        }
    }

    /// By folder name first, then by label, then either ignoring case.
    public func resolve(_ nameOrID: String, status: Bool = false) -> Profile? {
        let all = list(status: status)
        return all.first { $0.id == nameOrID }
            ?? all.first { $0.name == nameOrID }
            ?? all.first { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame || $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
    }

    public func isRunning(_ profile: Profile) -> pid_t? {
        runningMap()[ProfileStore.key(profile.path)]
    }

    /// A folder's own date only moves when direct children change, so look at files
    /// Electron and Claude rewrite while running. None means Claude never ran there.
    public static func lastUsed(_ path: URL) -> Date? {
        ["Preferences", "Local State", "config.json", "window-state.json", "Cookies", "Network/Cookies"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: path.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }.max()
    }

    /// nil when the name is fine, otherwise the reason it is not.
    public func validateName(_ name: String, exceptID: String? = nil) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("Name cannot be empty.", "Ad boş olamaz.")
        }
        if name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)) != nil {
            return L("Name cannot contain / : or \\.", "Ad / : veya \\ içeremez.")
        }
        if name.hasPrefix(".") || name != name.trimmingCharacters(in: .whitespaces) {
            return L("Name cannot start with a dot or start or end with a space.", "Ad nokta ile başlayamaz, boşlukla başlayıp bitemez.")
        }
        if name.count > 40 {
            return L("Name is too long (40 characters max).", "Ad çok uzun (en fazla 40 karakter).")
        }
        if exceptID != Profile.defaultID, name.caseInsensitiveCompare(Profile.defaultID) == .orderedSame {
            return L("'Default' is the name of your original account.", "'Default' asıl hesabınızın adı.")
        }
        // APFS is case-insensitive by default, so "work" and "Work" would share a folder.
        for p in list(status: false) where p.id != exceptID {
            if p.id.caseInsensitiveCompare(name) == .orderedSame || p.name.caseInsensitiveCompare(name) == .orderedSame {
                return L("A profile named '\(name)' already exists.", "'\(name)' adında bir profil zaten var.")
            }
        }
        if exceptID == nil, FileManager.default.fileExists(atPath: paths.profileDir(id: name).path) {
            return L("'\(name)' is already taken by \(paths.profileDir(id: name).path).", "'\(name)' zaten kullanımda: \(paths.profileDir(id: name).path)")
        }
        return nil
    }

    /// New accounts are created before anyone knows which login goes in them, so they are
    /// numbered after Default and can be renamed once signed in.
    public func nextAccountName() -> String {
        let word = L("Account", "Hesap")
        var n = 2
        while validateName("\(word) \(n)") != nil { n += 1 }
        return "\(word) \(n)"
    }

    public func create(name: String) throws -> Profile {
        if let problem = validateName(name) { throw SwitcherError(problem) }
        let path = try createFolder(id: name)
        return Profile(id: name, name: name, path: path)
    }

    /// Fails if the folder exists, so two writers racing for "Account N" (the panel and a
    /// command line run) can never both get it and start two Claudes on one folder.
    func createFolder(id: String) throws -> URL {
        let path = paths.profileDir(id: id)
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        do {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch CocoaError.fileWriteFileExists {
            throw SwitcherError(L("'\(id)' is already taken by \(path.path).", "'\(id)' zaten kullanımda: \(path.path)"))
        }
        return path
    }

    public func rename(_ profile: Profile, to newName: String) throws -> Profile {
        if let problem = validateName(newName, exceptID: profile.id) { throw SwitcherError(problem) }
        // The label lives in settings.json; when that cannot be saved, nothing may pretend it was.
        if let problem = settings.problem { throw SwitcherError(problem) }
        try settings.setLabel(profile.id, newName)
        return Profile(id: profile.id, name: newName, path: profile.path, pid: profile.pid, lastUsed: profile.lastUsed)
    }

    public func delete(_ profile: Profile) throws {
        if profile.isDefault {
            throw SwitcherError(L("The original account cannot be deleted.", "Asıl hesap silinemez."))
        }
        // Never anything but a profile folder of ours, directly under Application Support.
        let parent = ProfileStore.key(profile.path.deletingLastPathComponent())
        guard !profile.id.hasPrefix("."), !profile.id.contains("/"),
              parent == ProfileStore.key(paths.appSupport),
              profile.path.lastPathComponent == Paths.profilePrefix + profile.id else {
            throw SwitcherError(L("Refusing to delete '\(profile.path.path)'.", "'\(profile.path.path)' silinmeyecek."))
        }
        if isRunning(profile) != nil {
            throw SwitcherError(L("Quit '\(profile.name)' before deleting it.", "Silmeden önce '\(profile.name)' uygulamasından çıkın."))
        }
        // Checked before the folder goes to the Trash: afterwards the label could not be removed.
        if let problem = settings.problem { throw SwitcherError(problem) }
        if FileManager.default.fileExists(atPath: profile.path.path) {
            try remove(profile.path)
        }
        do {
            try settings.setLabel(profile.id, nil)
            try settings.forgetColor(profile.id)
        } catch {
            throw SwitcherError(L("'\(profile.name)' was moved to the Trash, but its label could not be removed: \(error.localizedDescription)",
                                  "'\(profile.name)' Çöp Kutusu'na taşındı, ancak etiketi kaldırılamadı: \(error.localizedDescription)"))
        }
    }
}
