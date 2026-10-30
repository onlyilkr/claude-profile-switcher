import Foundation

/// Byte-level helpers shared by the codecs. Everything read from a file is bounds- and overflow-checked.
private enum Wire {
    static func varint(_ bytes: [UInt8], _ pos: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < bytes.count {
            let b = bytes[pos]
            pos += 1
            let part = UInt64(b & 0x7F)
            if shift >= 64 || (shift == 63 && part > 1) { return nil }
            result |= part << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out = [UInt8]()
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
        return out
    }
}

/// Keys and values of Claude's Local Storage (a Chromium LevelDB) for the `https://claude.ai` origin.
enum LocalStorageCodec {
    private static func bad(_ reason: String) -> SwitcherError {
        SwitcherError("Claude's local data is not in the expected format.", logReason: reason)
    }

    static func key(_ name: String, origin: String = "https://claude.ai") -> Data {
        Data("_\(origin)".utf8) + Data([0x00, 0x01]) + (name.data(using: .isoLatin1) ?? Data(name.utf8))
    }

    static let metaKey = Data("META:https://claude.ai".utf8)

    /// Chromium stores a value as `0x01` + Latin-1 or `0x00` + UTF-16LE.
    static func decode(_ value: Data) throws -> String {
        guard let tag = value.first else { throw bad("local storage value not recognised") }
        let body = value.dropFirst()
        switch tag {
        case 0x01:
            if let s = String(data: body, encoding: .isoLatin1) { return s }
        case 0x00:
            if body.count % 2 == 0, let s = String(data: body, encoding: .utf16LittleEndian) { return s }
        default: break
        }
        throw bad("local storage value not recognised")
    }

    static func encode(_ text: String) -> Data {
        if text.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) {
            return Data([0x01]) + Data(text.unicodeScalars.map { UInt8($0.value) })
        }
        var out = Data([0x00])
        for u in text.utf16 { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
        return out
    }

    /// META is a protobuf: field 1 = last-modified (µs since 1601-01-01 UTC), field 2 = total size in bytes.
    /// Any other field, or a malformed value, is refused.
    static func updatedMeta(_ old: Data, sizeDelta: Int, now: Date) throws -> Data {
        let bytes = [UInt8](old)
        var pos = 0
        var size: UInt64?
        var sawTime = false
        while pos < bytes.count {
            let tag = bytes[pos]
            pos += 1
            guard tag == 0x08 || tag == 0x10, let v = Wire.varint(bytes, &pos) else { throw bad("local storage meta not recognised") }
            if tag == 0x08 {
                guard !sawTime else { throw bad("local storage meta not recognised") }
                sawTime = true
            } else {
                guard size == nil else { throw bad("local storage meta not recognised") }
                size = v
            }
        }
        guard sawTime, let oldSize = size, oldSize <= UInt64(Int.max) else { throw bad("local storage meta not recognised") }
        let (sum, overflow) = Int(oldSize).addingReportingOverflow(sizeDelta)
        guard !overflow else { throw bad("local storage meta not recognised") }
        let seconds = now.timeIntervalSince1970 + 11_644_473_600
        guard seconds >= 0, seconds < 1e12 else { throw bad("local storage meta not recognised") }
        let micros = UInt64(seconds * 1_000_000)
        return Data([0x08] + Wire.encodeVarint(micros) + [0x10] + Wire.encodeVarint(UInt64(max(sum, 0))))
    }
}

/// The IndexedDB record that holds the pinned Code chats. It is rebuilt byte-for-byte except for the JSON.
struct IndexedDBPinRecord {
    let key: Data
    /// Record-version varint and every byte up to and including the `0x22` string tag.
    let envelope: Data
    /// The parsed JSON text: `{"state":{"starredIds":[...]},"version":..,"updatedAt":..}`.
    var state: [String: Any]

    var starredIds: [String] {
        get { ((state["state"] as? [String: Any])?["starredIds"] as? [String]) ?? [] }
        set {
            var inner = (state["state"] as? [String: Any]) ?? [:]
            inner["starredIds"] = newValue
            state["state"] = inner
        }
    }

    /// Throws instead of ever producing an empty record: writing `{}` would wipe the account's pins.
    func encoded(updatedAt: Date) throws -> Data {
        var obj = state
        let ms = (updatedAt.timeIntervalSince1970 * 1000).rounded()
        guard ms.isFinite, ms >= 0, ms < 1e15 else { throw IndexedDBPins.bad() }
        obj["updatedAt"] = Int(ms)
        guard JSONSerialization.isValidJSONObject(obj),
              let raw = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        else { throw IndexedDBPins.bad() }
        // Latin-1 string: anything above U+00FF is written as a \u escape.
        var text = [UInt8]()
        for u in String(decoding: raw, as: UTF8.self).utf16 {
            if u <= 0xFF { text.append(UInt8(u)) } else { text += Array(String(format: "\\u%04x", u).utf8) }
        }
        return envelope + Data(Wire.encodeVarint(UInt64(text.count))) + Data(text)
    }
}

enum IndexedDBPins {
    static let storeName = "store:pin-state:dframe-starred-code"

    static func bad() -> SwitcherError {
        SwitcherError("Claude's pin list is not in the expected format.", logReason: "pin store format not recognised")
    }

    /// Key = KeyPrefix (database, object store and index ids; index 1 = data record) + `01` + varint(length) + UTF-16BE name.
    private static func isPinKey(_ key: Data) -> Bool {
        let b = [UInt8](key)
        guard let first = b.first else { return false }
        let dbLen = Int((first >> 5) & 7) + 1, osLen = Int((first >> 2) & 7) + 1, idxLen = Int(first & 3) + 1
        let indexStart = 1 + dbLen + osLen
        let nameStart = indexStart + idxLen
        guard b.count >= nameStart else { return false }
        guard b[indexStart] == 1, b[(indexStart + 1)..<nameStart].allSatisfy({ $0 == 0 }) else { return false }
        var expected: [UInt8] = [0x01] + Wire.encodeVarint(UInt64(storeName.utf16.count))
        for u in storeName.utf16 { expected += [UInt8(u >> 8), UInt8(u & 0xFF)] }
        return Array(b[nameStart...]) == expected
    }

    static func find(in reader: LevelDBReader) throws -> IndexedDBPinRecord? {
        let live = try reader.entries(where: isPinKey).filter(\.isPut)
        guard live.count <= 1 else { throw bad() }
        guard let e = live.first else { return nil }
        return try parse(key: e.key, value: [UInt8](e.value))
    }

    private static func parse(key: Data, value v: [UInt8]) throws -> IndexedDBPinRecord {
        var pos = 0
        guard Wire.varint(v, &pos) != nil else { throw bad() }
        let fixed: [UInt8] = [0xFF, 0x15, 0xFE]
        guard v.count >= pos + 3, Array(v[pos..<(pos + 3)]) == fixed else { throw bad() }
        pos += 3 + 12                       // 12 bytes after FE
        guard v.count >= pos + 3, v[pos] == 0xFF, v[pos + 2] == 0x22 else { throw bad() }
        pos += 3
        let envelope = Data(v[..<pos])
        guard let len = Wire.varint(v, &pos), len == UInt64(v.count - pos) else { throw bad() }
        guard let text = String(data: Data(v[pos...]), encoding: .isoLatin1),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let inner = obj["state"] as? [String: Any], inner["starredIds"] is [String],
              obj["version"] is Int, obj["updatedAt"] is Int
        else { throw bad() }
        return IndexedDBPinRecord(key: key, envelope: envelope, state: obj)
    }
}
