import Foundation
@testable import SwitcherCore

/// Test-only builder of a synthetic account folder holding both pin databases (IndexedDB and Local Storage),
/// laid out like Claude's: `<root>/<id>/IndexedDB/https_claude.ai_0.indexeddb.leveldb` and `<root>/<id>/Local Storage/leveldb`.
enum ClaudeStoreFixture {
    /// How Local Storage values are encoded: by their content (Latin-1 when possible) or always UTF-16.
    enum ValueEncoding { case byContent, utf16 }

    static let storeName = "store:pin-state:dframe-starred-code"
    static func idbFolder(_ p: Profile) -> URL { p.path.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb") }
    static func lsFolder(_ p: Profile) -> URL { p.path.appendingPathComponent("Local Storage/leveldb") }
    static func configFile(_ p: Profile) -> URL { p.path.appendingPathComponent("claude_desktop_config.json") }

    /// - Parameters:
    ///   - root: folder that will hold the account folder.
    ///   - id: profile id, also the account folder's name.
    ///   - name: profile display name.
    ///   - starredIds: ids in the IndexedDB `starredIds`; nil = no pin record in IndexedDB at all.
    ///   - pinnedOrder: `pinnedOrder` in `dframe-store` and `dframe-local-slice`; nil = neither key exists.
    ///   - listMirror: value of `LSS-persisted.starred-local-code-sessions`; nil = key missing.
    ///   - lsVersion: Local Storage `VERSION` value; nil = key missing.
    ///   - lsEncoding: encoding of the Local Storage JSON values.
    ///   - includeMeta: whether the `META:https://claude.ai` record exists.
    ///   - config: contents of `claude_desktop_config.json`; nil = no such file.
    ///   - databaseId: IndexedDB database id byte in the record key (varies per account).
    static func makeProfile(in root: URL, id: String = "p1", name: String = "Test", starredIds: [String]? = ["local_a"],
                            pinnedOrder: [String]? = [], listMirror: [String]? = ["local_a"], lsVersion: String? = "1",
                            lsEncoding: ValueEncoding = .byContent, includeMeta: Bool = true,
                            config: String? = "{\"k\":1}", databaseId: UInt8 = 1) throws -> Profile {
        let profile = Profile(id: id, name: name, path: root.appendingPathComponent(id))
        let v = LevelDBFixture.varint

        // IndexedDB: one unrelated record, plus the pin record when requested.
        var idbOps: [(key: Data, value: Data?)] = [(Data([0x00, databaseId, 0x01, 0x01, 0x01, 0x00]), Data([0x01]))]
        if let ids = starredIds {
            var key: [UInt8] = [0x00, databaseId, 0x01, 0x01, 0x01]
            key += v(UInt64(storeName.utf16.count))
            for u in storeName.utf16 { key += [UInt8(u >> 8), UInt8(u & 0xFF)] }
            let body = Array(try json(["state": ["starredIds": ids], "version": 0, "updatedAt": 1]).utf8)
            let value = [0x04, 0xFF, 0x15, 0xFE] + [UInt8](repeating: 0, count: 12) + [0xFF, 0x10, 0x22] + v(UInt64(body.count)) + body
            idbOps.append((Data(key), Data(value)))
        }
        let idb = try LevelDBFixture(folder: idbFolder(profile))
        try idb.writeLog(number: 3, batches: [.init(sequence: 1, ops: idbOps)])
        try idb.writeManifest(logNumber: 3, lastSequence: UInt64(idbOps.count), liveTables: [])
        try Data().write(to: idbFolder(profile).appendingPathComponent("LOCK"))

        // Local Storage.
        func enc(_ text: String) -> Data {
            lsEncoding == .utf16 ? Data([0x00]) + text.data(using: .utf16LittleEndian)! : LocalStorageCodec.encode(text)
        }
        var ls: [(key: Data, value: Data?)] = []
        if let version = lsVersion { ls.append((Data("VERSION".utf8), Data(version.utf8))) }
        if includeMeta { ls.append((LocalStorageCodec.metaKey, Data([0x08] + v(1) + [0x10] + v(500)))) }
        if let mirror = listMirror {
            ls.append((LocalStorageCodec.key("LSS-persisted.starred-local-code-sessions"),
                       enc(try json(["value": mirror, "tabId": "", "timestamp": 1]))))
        }
        if let order = pinnedOrder {
            ls.append((LocalStorageCodec.key("dframe-store"),
                       enc(try json(["state": ["pinnedOrder": order, "theme": "dark"], "version": 2, "shared": false]))))
            ls.append((LocalStorageCodec.key("LSS-persisted.dframe-local-slice"),
                       enc(try json(["value": ["pinnedOrder": order, "homeProjectsPinnedOrder": ["p1"]], "tabId": "", "timestamp": 1]))))
        }
        let lsdb = try LevelDBFixture(folder: lsFolder(profile))
        try lsdb.writeLog(number: 3, batches: [.init(sequence: 1, ops: ls)])
        try lsdb.writeManifest(logNumber: 3, lastSequence: UInt64(ls.count), liveTables: [])
        try Data().write(to: lsFolder(profile).appendingPathComponent("LOCK"))

        if let config { try Data(config.utf8).write(to: configFile(profile)) }
        return profile
    }

    /// Every file under `folder` as relative path -> bytes, for before/after comparisons.
    static func snapshot(_ folder: URL) throws -> [String: Data] {
        var out = [String: Data]()
        let base = folder.resolvingSymlinksInPath().path
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])! {
            let u = url.resolvingSymlinksInPath()
            guard (try u.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            out[String(u.path.dropFirst(base.count))] = try Data(contentsOf: u)
        }
        return out
    }

    private static func json(_ obj: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
