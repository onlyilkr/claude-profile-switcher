import Foundation

/// An account's pinned Code chats as Claude keeps them.
struct ClaudePins: Equatable {
    /// IndexedDB `starredIds`, in stored order.
    let starred: [String]
    /// Local Storage `pinnedOrder`, raw entries (`code:<id>`, other kinds, stale ids).
    let order: [String]

    /// The sidebar order: `pinnedOrder`'s `code:` ids that are starred, then the other starred ids sorted.
    var sidebar: [String] {
        let starredSet = Set(starred)
        var seen = Set<String>()
        var out = [String]()
        for entry in order where entry.hasPrefix("code:") {
            let id = String(entry.dropFirst(5))
            if starredSet.contains(id), seen.insert(id).inserted { out.append(id) }
        }
        return out + starred.filter { !seen.contains($0) }.sorted()
    }
}

/// Reads and writes the pin store of one account: pins in IndexedDB, sidebar order in Local Storage.
/// Writes happen only while both databases are locked (the account is closed), after a backup, and are
/// undone from that backup if anything after the first append fails.
enum ClaudePinStore {
    /// Test seam: runs after the Local Storage write and before the IndexedDB write.
    static var beforeIndexedDBWrite: (() throws -> Void)?

    private static let storeKey = LocalStorageCodec.key("dframe-store")
    private static let sliceKey = LocalStorageCodec.key("LSS-persisted.dframe-local-slice")
    private static let mirrorKey = LocalStorageCodec.key("LSS-persisted.starred-local-code-sessions")
    private static let versionKey = Data("VERSION".utf8)

    private static func idbFolder(_ p: Profile) -> URL { p.path.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb") }
    private static func lsFolder(_ p: Profile) -> URL { p.path.appendingPathComponent("Local Storage/leveldb") }

    private static func unrecognised() -> SwitcherError {
        SwitcherError(L("This Claude version stores pins in a way the switcher does not recognise, so pins were not synced.",
                        "Bu Claude sürümü pinleri switcher'ın tanımadığı bir biçimde saklıyor, bu yüzden pinler eşitlenmedi."),
                      logReason: "pin store format not recognised")
    }

    // MARK: Read

    /// nil = the account has no pin record yet. A missing `dframe-store` reads as "no explicit order".
    static func read(_ profile: Profile, tolerateTornTail: Bool) throws -> ClaudePins? {
        guard let record = try IndexedDBPins.find(in: LevelDBReader(folder: idbFolder(profile), tolerateTornTail: tolerateTornTail)) else { return nil }
        let ls = LevelDBReader(folder: lsFolder(profile), tolerateTornTail: tolerateTornTail)
        var order = [String]()
        if let e = try ls.newest(storeKey), e.isPut {
            order = try pinnedOrder(of: try parse(e).obj)
        }
        return ClaudePins(starred: record.starredIds, order: order)
    }

    // MARK: Write

    /// Makes `sidebar` the account's pins and their order. Returns false when nothing needed writing.
    static func write(_ sidebar: [String], to profile: Profile, backups: URL, now: Date = Date()) throws -> Bool {
        var seen = Set<String>()
        let wanted = sidebar.filter { seen.insert($0).inserted }

        // Unlocked pre-check, so an account that is already right (or unusable) never needs the locks.
        let first = try load(profile)
        if first.pins.sidebar == wanted && first.pins.starred == wanted { return false }

        return try LevelDBLock.withExclusive(lsFolder(profile)) {
            try LevelDBLock.withExclusive(idbFolder(profile)) {
                let state = try load(profile)   // the data to change comes from the locked read
                if state.pins.sidebar == wanted && state.pins.starred == wanted { return false }
                let plan = try plan(wanted, state, now: now)
                let backup = try backUp(profile, backups: backups, now: now)
                do {
                    _ = try LevelDBWriter(folder: lsFolder(profile)).append(plan.lsPuts)
                    try beforeIndexedDBWrite?()
                    _ = try LevelDBWriter(folder: idbFolder(profile)).append([plan.idbPut])
                    try verify(profile, plan, sidebar: wanted)
                } catch {
                    try restore(profile, from: backup)
                    throw SwitcherError(L("Could not sync pins; Claude's data was left unchanged.",
                                          "Pinler eşitlenemedi; Claude verisi değişmeden bırakıldı."), logReason: "pin store write failed")
                }
                return true
            }
        }
    }

    // MARK: Loading and planning

    private struct Loaded {
        let pins: ClaudePins
        let sliceOrder: [String]
        let record: IndexedDBPinRecord
        let store: (entry: LevelDBEntry, obj: [String: Any])
        let slice: (entry: LevelDBEntry, obj: [String: Any])
        let mirror: (entry: LevelDBEntry, obj: [String: Any])
        let meta: Data
    }

    private struct Plan {
        let lsPuts: [(key: Data, value: Data)]
        let idbPut: (key: Data, value: Data)
    }

    /// Reads everything a write needs (no torn tail allowed) and refuses unless it is exactly the observed format.
    private static func load(_ profile: Profile) throws -> Loaded {
        guard let record = try IndexedDBPins.find(in: LevelDBReader(folder: idbFolder(profile))) else {
            throw SwitcherError(L("Claude has not saved pins in '\(profile.name)' yet. Pin one chat there once, then pin sync can follow.",
                                  "Claude '\(profile.name)' hesabında henüz pin kaydetmedi. Orada bir sohbeti bir kez pinleyin, sonra pin eşitleme çalışır."),
                                logReason: "no pin record yet")
        }
        let ls = LevelDBReader(folder: lsFolder(profile))
        func live(_ key: Data) throws -> LevelDBEntry {
            guard let e = try ls.newest(key), e.isPut else { throw unrecognised() }
            return e
        }
        guard try live(versionKey).value == Data("1".utf8) else { throw unrecognised() }
        let meta = try live(LocalStorageCodec.metaKey).value
        let store = try parse(try live(storeKey))
        let slice = try parse(try live(sliceKey))
        let mirror = try parse(try live(mirrorKey))
        let order = try pinnedOrder(of: store.obj)
        guard let value = slice.obj["value"] as? [String: Any], let sliceOrder = value["pinnedOrder"] as? [String], isNumber(slice.obj["timestamp"]),
              isStrings(mirror.obj["value"]), isNumber(mirror.obj["timestamp"]) else { throw unrecognised() }
        return Loaded(pins: ClaudePins(starred: record.starredIds, order: order), sliceOrder: sliceOrder, record: record,
                      store: store, slice: slice, mirror: mirror, meta: meta)
    }

    private static func parse(_ e: LevelDBEntry) throws -> (entry: LevelDBEntry, obj: [String: Any]) {
        guard let text = try? LocalStorageCodec.decode(e.value),
              let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { throw unrecognised() }
        return (e, obj)
    }

    private static func pinnedOrder(of store: [String: Any]) throws -> [String] {
        guard let state = store["state"] as? [String: Any], let order = state["pinnedOrder"] as? [String] else { throw unrecognised() }
        return order
    }

    private static func isStrings(_ x: Any?) -> Bool { x is [String] }

    /// A JSON number, not a boolean (which Foundation also bridges to NSNumber).
    private static func isNumber(_ x: Any?) -> Bool {
        guard let n = x as? NSNumber else { return false }
        return CFGetTypeID(n) != CFBooleanGetTypeID()
    }

    private static func plan(_ wanted: [String], _ s: Loaded, now: Date) throws -> Plan {
        let ms = (now.timeIntervalSince1970 * 1000).rounded()
        guard ms.isFinite, ms >= 0, ms < 1e15 else { throw unrecognised() }
        let stamp = Int(ms)

        // New entries first, then every other existing entry in its old relative order.
        let fresh = wanted.map { "code:" + $0 }
        let freshSet = Set(fresh)
        // Each key keeps its own other entries.
        let order = fresh + s.pins.order.filter { !freshSet.contains($0) }
        let sliceOrder = fresh + s.sliceOrder.filter { !freshSet.contains($0) }

        var mirror = s.mirror.obj
        mirror["value"] = wanted
        mirror["timestamp"] = stamp
        var store = s.store.obj
        var state = store["state"] as? [String: Any] ?? [:]
        state["pinnedOrder"] = order
        store["state"] = state
        var slice = s.slice.obj
        var value = slice["value"] as? [String: Any] ?? [:]
        value["pinnedOrder"] = sliceOrder
        slice["value"] = value
        slice["timestamp"] = stamp

        let puts = [(mirrorKey, mirror, s.mirror.entry), (storeKey, store, s.store.entry), (sliceKey, slice, s.slice.entry)]
        var changed = [(key: Data, value: Data)]()
        var delta = 0
        for (key, obj, old) in puts {
            guard JSONSerialization.isValidJSONObject(obj),
                  let raw = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { throw unrecognised() }
            let encoded = LocalStorageCodec.encode(String(decoding: raw, as: UTF8.self))
            delta += encoded.count - old.value.count
            changed.append((key, encoded))
        }
        let meta = try LocalStorageCodec.updatedMeta(s.meta, sizeDelta: delta, now: now)
        var rec = s.record
        rec.starredIds = wanted
        return Plan(lsPuts: changed + [(LocalStorageCodec.metaKey, meta)], idbPut: (rec.key, try rec.encoded(updatedAt: now)))
    }

    /// The new values must be the newest ones for their keys, and the pins must read back as written.
    private static func verify(_ profile: Profile, _ plan: Plan, sidebar: [String]) throws {
        let ls = LevelDBReader(folder: lsFolder(profile))
        for p in plan.lsPuts {
            guard let e = try ls.newest(p.key), e.isPut, e.value == p.value else { throw unrecognised() }
        }
        guard let e = try LevelDBReader(folder: idbFolder(profile)).newest(plan.idbPut.key), e.isPut, e.value == plan.idbPut.value,
              let pins = try read(profile, tolerateTornTail: false), pins.sidebar == sidebar, pins.starred == sidebar else { throw unrecognised() }
    }

    // MARK: Backup and restore

    private static let keptBackups = 5

    /// The database folders relative to the account folder.
    private static func relativeItems(_ p: Profile) -> [String] {
        [idbFolder(p), lsFolder(p)].map { String($0.path.dropFirst(p.path.path.count + 1)) }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }

    /// Copies both databases and the config to `<backups>/<time>/<profile id>/` and prunes older copies of this profile.
    private static func backUp(_ profile: Profile, backups: URL, now: Date) throws -> URL {
        let fm = FileManager.default
        let fail = SwitcherError(L("Could not back up Claude's data, so pins were not synced.", "Claude verisi yedeklenemedi, bu yüzden pinler eşitlenmedi."),
                                 logReason: "pin store backup failed")
        var date = now
        var dest = backups.appendingPathComponent(stamp(date)).appendingPathComponent(profile.id)
        for _ in 0..<1000 where fm.fileExists(atPath: dest.path) {   // same millisecond as an earlier backup
            date = date.addingTimeInterval(0.001)
            dest = backups.appendingPathComponent(stamp(date)).appendingPathComponent(profile.id)
        }
        guard !fm.fileExists(atPath: dest.path) else { throw fail }
        do {
            try makeFolder(dest, below: backups)
            for rel in relativeItems(profile) {
                let live = profile.path.appendingPathComponent(rel), target = dest.appendingPathComponent(rel)
                try makeFolder(target, below: dest)
                // Everything but LOCK: closing any descriptor on LOCK would drop the lock this process holds on it.
                for name in try fm.contentsOfDirectory(atPath: live.path) where name != "LOCK" {
                    try fm.copyItem(at: live.appendingPathComponent(name), to: target.appendingPathComponent(name))
                }
            }
            let config = profile.path.appendingPathComponent("claude_desktop_config.json")
            if fm.fileExists(atPath: config.path) { try fm.copyItem(at: config, to: dest.appendingPathComponent(config.lastPathComponent)) }
        } catch {
            try? fm.removeItem(at: dest)
            let stampDir = dest.deletingLastPathComponent()
            if ((try? fm.contentsOfDirectory(atPath: stampDir.path)) ?? ["x"]).isEmpty { try? fm.removeItem(at: stampDir) }
            throw fail
        }
        prune(profile.id, backups: backups, keeping: dest.deletingLastPathComponent().lastPathComponent)
        return dest
    }

    /// Creates `folder` and every missing folder between it and `root` (which is created too) with 0700:
    /// a backup holds the config, which can carry MCP environment values.
    private static func makeFolder(_ folder: URL, below root: URL) throws {
        let fm = FileManager.default
        var chain = [folder]
        while chain.last!.standardizedFileURL.path != root.standardizedFileURL.path, chain.last!.pathComponents.count > root.pathComponents.count {
            chain.append(chain.last!.deletingLastPathComponent())
        }
        for url in chain.reversed() where !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: url == chain.last, attributes: [.posixPermissions: 0o700])
            chmod(url.path, 0o700)
        }
    }

    /// Keeps the newest `keptBackups` time folders that hold this profile; other profiles' copies are left alone.
    private static func prune(_ id: String, backups: URL, keeping current: String) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? [])
            .filter { $0.range(of: #"^\d{8}-\d{6}-\d{3}$"#, options: .regularExpression) != nil }
            .filter { fm.fileExists(atPath: backups.appendingPathComponent($0).appendingPathComponent(id).path) }
            .filter { $0 != current }
            .sorted(by: >)
        // The backup just taken is never pruned, even when the clock is behind older copies.
        for name in names.dropFirst(keptBackups - 1) {
            let dir = backups.appendingPathComponent(name)
            try? fm.removeItem(at: dir.appendingPathComponent(id))
            if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["x"]).isEmpty { try? fm.removeItem(at: dir) }
        }
    }

    /// Puts both database folders back as they were in `backup`. The LOCK files stay: we hold them.
    private static func restore(_ profile: Profile, from backup: URL) throws {
        let fm = FileManager.default
        let fail = SwitcherError(L("Pins could not be written and Claude's data could not be restored automatically. Your backup is in \(backup.path).",
                                   "Pinler yazılamadı ve Claude verisi otomatik geri yüklenemedi. Yedeğiniz şurada: \(backup.path)."),
                                 logReason: "pin store restore failed")
        do {
            for rel in relativeItems(profile) {
                let live = profile.path.appendingPathComponent(rel), saved = backup.appendingPathComponent(rel)
                let savedNames = Set(try fm.contentsOfDirectory(atPath: saved.path))
                for name in try fm.contentsOfDirectory(atPath: live.path) where name != "LOCK" {
                    try fm.removeItem(at: live.appendingPathComponent(name))
                }
                for name in savedNames {
                    try fm.copyItem(at: saved.appendingPathComponent(name), to: live.appendingPathComponent(name))
                }
                // Re-verify: the same files, byte for byte, and databases that read without tolerance.
                for name in savedNames {
                    guard fm.contentsEqual(atPath: saved.appendingPathComponent(name).path, andPath: live.appendingPathComponent(name).path) else { throw fail }
                }
                guard try fm.contentsOfDirectory(atPath: live.path).filter({ $0 != "LOCK" }).count == savedNames.count else { throw fail }
            }
            _ = try IndexedDBPins.find(in: LevelDBReader(folder: idbFolder(profile)))
            _ = try LevelDBReader(folder: lsFolder(profile)).maxSequence()
        } catch {
            throw fail
        }
    }
}
