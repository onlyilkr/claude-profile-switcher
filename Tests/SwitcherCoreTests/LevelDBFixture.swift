import Foundation
@testable import SwitcherCore

/// Test-only writer of synthetic LevelDB folders (CURRENT, MANIFEST, .log, .ldb) in the layout Chromium
/// uses. Keys and values are arbitrary bytes, so Local Storage and IndexedDB shaped keys can go through it.
struct LevelDBFixture {
    /// One put (`value` set) or delete (`value` nil) of `key` at `sequence`.
    struct Record {
        var key: Data
        var value: Data?
        var sequence: UInt64
        init(_ key: Data, _ value: Data?, seq: UInt64) { self.key = key; self.value = value; self.sequence = seq }
    }
    /// Operations written as a single write batch; their sequences are `sequence`, `sequence + 1`, ...
    struct Batch {
        var sequence: UInt64
        var ops: [(key: Data, value: Data?)]
    }
    enum Compression { case none, snappy }

    let folder: URL

    /// Creates `folder` (and parents) if needed.
    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A fresh, empty folder under the system temp dir; the caller removes it.
    static func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("leveldb-fixture-\(UUID().uuidString)")
    }

    static func name(_ number: UInt64, _ ext: String) -> String { String(format: "%06llu.%@", number, ext) }

    // MARK: Files

    /// Writes `<number>.log`; `tearLastRecord` cuts the final physical record in half like a crash mid-write.
    func writeLog(number: UInt64, batches: [Batch], tearLastRecord: Bool = false) throws {
        let bytes = Self.logFile(batches.map(Self.encode), tearLastRecord: tearLastRecord)
        try Data(bytes).write(to: folder.appendingPathComponent(Self.name(number, "log")))
    }

    /// Writes `<number>.ldb` from records (sorted here by key, then newest first).
    func writeTable(number: UInt64, records: [Record], compression: Compression = .none, entriesPerBlock: Int = 16) throws {
        let sorted = records.sorted {
            $0.key == $1.key ? $0.sequence > $1.sequence : $0.key.lexicographicallyPrecedes($1.key)
        }
        var file = [UInt8]()
        var index = [([UInt8], [UInt8])]()   // last key of each block -> handle
        var i = 0
        while i < sorted.count {
            let chunk = sorted[i..<min(i + entriesPerBlock, sorted.count)]
            let items = chunk.map { r -> ([UInt8], [UInt8]) in
                let tag = r.sequence << 8 | (r.value == nil ? 0 : 1)
                return ([UInt8](r.key) + Self.le(tag, 8), [UInt8](r.value ?? Data()))
            }
            let handle = Self.appendBlock(Self.block(items, restartInterval: 16), to: &file, compression)
            index.append((items.last!.0, handle))
            i += entriesPerBlock
        }
        let metaHandle = Self.appendBlock(Self.block([], restartInterval: 16), to: &file, .none)
        let indexHandle = Self.appendBlock(Self.block(index, restartInterval: 1), to: &file, .none)
        var footer = metaHandle + indexHandle
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        file += footer + Self.le(0xdb4775248b80fb57, 8)
        try Data(file).write(to: folder.appendingPathComponent(Self.name(number, "ldb")))
    }

    /// Writes CURRENT and `MANIFEST-<number>`. `deletedTables` are first added, then removed by a second
    /// VersionEdit, so they must not appear live. `prevLogNumber` 0 omits that field.
    func writeManifest(number: UInt64 = 1, logNumber: UInt64, prevLogNumber: UInt64 = 0, lastSequence: UInt64,
                       liveTables: [UInt64], deletedTables: [UInt64] = []) throws {
        func lp(_ b: [UInt8]) -> [UInt8] { Self.varint(UInt64(b.count)) + b }
        let dummyKey = lp([0x61] + Self.le(1, 8))
        var first = Self.varint(1) + lp(Array("leveldb.BytewiseComparator".utf8))
        first += Self.varint(2) + Self.varint(logNumber)
        if prevLogNumber != 0 { first += Self.varint(9) + Self.varint(prevLogNumber) }
        first += Self.varint(3) + Self.varint(logNumber + 10)
        first += Self.varint(4) + Self.varint(lastSequence)
        first += Self.varint(5) + Self.varint(0) + dummyKey   // compact pointer, ignored by readers
        for t in liveTables + deletedTables { first += Self.varint(7) + Self.varint(0) + Self.varint(t) + Self.varint(100) + dummyKey + dummyKey }
        var records = [first]
        if !deletedTables.isEmpty {
            records.append(deletedTables.reduce([UInt8]()) { $0 + Self.varint(6) + Self.varint(0) + Self.varint($1) })
        }
        let name = "MANIFEST-" + String(format: "%06llu", number)
        try Data(Self.logFile(records, tearLastRecord: false)).write(to: folder.appendingPathComponent(name))
        try Data((name + "\n").utf8).write(to: folder.appendingPathComponent("CURRENT"))
    }

    // MARK: Encoding helpers

    /// A log file holding `payloads`, fragmented across 32 KiB blocks like LevelDB does.
    static func logFile(_ payloads: [[UInt8]], tearLastRecord: Bool) -> [UInt8] {
        var out = [UInt8](), lastStart = 0
        func emit(_ type: UInt8, _ part: ArraySlice<UInt8>) {
            lastStart = out.count
            let crc = CRC32C.masked(CRC32C.checksum(Array(part), seed: CRC32C.checksum([type])))
            out += le(UInt64(crc), 4) + le(UInt64(part.count), 2) + [type] + part
        }
        for p in payloads {
            var rest = p[...], first = true
            repeat {
                var left = 32768 - out.count % 32768
                if left < 7 { out += [UInt8](repeating: 0, count: left); left = 32768 }
                let n = min(rest.count, left - 7)
                let isLast = n == rest.count
                emit(first && isLast ? 1 : first ? 2 : isLast ? 4 : 3, rest.prefix(n))
                rest = rest.dropFirst(n); first = false
            } while !rest.isEmpty
        }
        if tearLastRecord { out.removeLast((out.count - lastStart) / 2) }
        return out
    }

    /// A write batch: sequence, count, then put (1) / delete (0) operations.
    static func encode(_ batch: Batch) -> [UInt8] {
        var b = le(batch.sequence, 8) + le(UInt64(batch.ops.count), 4)
        for op in batch.ops {
            b += [op.value == nil ? 0 : 1] + varint(UInt64(op.key.count)) + [UInt8](op.key)
            if let v = op.value { b += varint(UInt64(v.count)) + [UInt8](v) }
        }
        return b
    }

    /// Prefix-compressed block with a restart array; `items` must already be in key order.
    static func block(_ items: [([UInt8], [UInt8])], restartInterval: Int) -> [UInt8] {
        var out = [UInt8](), restarts: [UInt32] = [0], prev = [UInt8]()
        for (n, (key, value)) in items.enumerated() {
            if n > 0 && n % restartInterval == 0 { restarts.append(UInt32(out.count)); prev = [] }
            var shared = 0
            while shared < min(prev.count, key.count) && prev[shared] == key[shared] { shared += 1 }
            out += varint(UInt64(shared)) + varint(UInt64(key.count - shared)) + varint(UInt64(value.count))
            out += key[shared...] + value
            prev = key
        }
        for r in restarts { out += le(UInt64(r), 4) }
        return out + le(UInt64(restarts.count), 4)
    }

    /// Appends contents + compression type + masked CRC; returns the block handle (offset, size varints).
    static func appendBlock(_ contents: [UInt8], to file: inout [UInt8], _ compression: Compression) -> [UInt8] {
        let stored = compression == .snappy ? snappyLiteral(contents) : contents
        let type: UInt8 = compression == .snappy ? 1 : 0
        let handle = varint(UInt64(file.count)) + varint(UInt64(stored.count))
        let crc = CRC32C.masked(CRC32C.checksum([type], seed: CRC32C.checksum(stored)))
        file += stored + [type] + le(UInt64(crc), 4)
        return handle
    }

    /// A valid Snappy stream made of a single literal (no compression).
    static func snappyLiteral(_ bytes: [UInt8]) -> [UInt8] {
        var out = varint(UInt64(bytes.count))
        let len = bytes.count - 1
        if len < 60 { out.append(UInt8(len << 2)) }
        else {
            var extra = [UInt8](), v = len
            while v > 0 { extra.append(UInt8(v & 0xFF)); v >>= 8 }
            out.append(UInt8((59 + extra.count) << 2)); out += extra
        }
        return out + bytes
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out = [UInt8]()
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        return out + [UInt8(v)]
    }

    static func le(_ value: UInt64, _ width: Int) -> [UInt8] { (0..<width).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) } }
}
