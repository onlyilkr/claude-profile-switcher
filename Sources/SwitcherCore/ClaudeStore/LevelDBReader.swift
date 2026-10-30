import Foundation

/// One record of a LevelDB database: a put or a deletion of `key`, stamped with its sequence number.
struct LevelDBEntry: Equatable {
    let key: Data
    let sequence: UInt64
    let isPut: Bool
    let value: Data
}

/// Read-only access to a LevelDB folder (CURRENT, MANIFEST, write-ahead logs, tables), the way Chromium
/// lays it out. Only files the MANIFEST still lists are read, so tables awaiting deletion are ignored.
/// Never writes. Ordering is not relied on: every record is scanned and the highest sequence wins, which
/// also works for databases that use a custom key comparator.
struct LevelDBReader {
    let folder: URL
    /// Accept a half-written last log record: set when the database may be open in a running app.
    let tolerateTornTail: Bool

    init(folder: URL, tolerateTornTail: Bool = false) {
        self.folder = folder
        self.tolerateTornTail = tolerateTornTail
    }

    private static func fail() -> SwitcherError {
        SwitcherError("Claude's local data is not in the expected format.", logReason: "leveldb read failed")
    }

    // MARK: Public API

    func manifest() throws -> (logNumber: UInt64, prevLogNumber: UInt64, lastSequence: UInt64, liveTables: [UInt64]) {
        guard let current = try? Data(contentsOf: folder.appendingPathComponent("CURRENT")),
              let text = String(data: current, encoding: .utf8), text.hasSuffix("\n") else { throw Self.fail() }
        let name = String(text.dropLast())
        // A name from CURRENT must stay inside the folder.
        guard name.hasPrefix("MANIFEST-"), !name.contains("/") else { throw Self.fail() }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { throw Self.fail() }

        var logNumber: UInt64 = 0, prevLog: UInt64 = 0, lastSeq: UInt64 = 0
        var live = Set<UInt64>()
        for edit in try Self.logRecords([UInt8](data), tolerateTornTail: tolerateTornTail) {
            var c = Cursor(edit)
            while !c.atEnd {
                switch try c.varint() {
                case 1: _ = try c.lengthPrefixed()                       // comparator name
                case 2: logNumber = try c.varint()
                case 3: _ = try c.varint()                               // next file number
                case 4: lastSeq = try c.varint()
                case 5: _ = try c.varint(); _ = try c.lengthPrefixed()   // compact pointer
                case 6: _ = try c.varint(); live.remove(try c.varint())  // deleted file
                case 7:                                                  // new file
                    _ = try c.varint()
                    let number = try c.varint()
                    _ = try c.varint()
                    _ = try c.lengthPrefixed(); _ = try c.lengthPrefixed()
                    live.insert(number)
                case 9: prevLog = try c.varint()
                default: throw Self.fail()
                }
            }
        }
        return (logNumber, prevLog, lastSeq, live.sorted())
    }

    func currentLogURL() throws -> URL {
        folder.appendingPathComponent(Self.fileName(try manifest().logNumber, "log"))
    }

    func newest(_ key: Data) throws -> LevelDBEntry? {
        try entries { $0 == key }.first
    }

    /// The newest record of every key `match` accepts, ordered by key bytes.
    func entries(where match: (Data) -> Bool) throws -> [LevelDBEntry] {
        var best = [Data: LevelDBEntry]()
        try scan { e in
            guard match(e.key) else { return }
            if let old = best[e.key], old.sequence >= e.sequence { return }
            best[e.key] = e
        }
        return best.values.sorted { $0.key.lexicographicallyPrecedes($1.key) }
    }

    func maxSequence() throws -> UInt64 {
        var m = try manifest().lastSequence
        try scan { m = max(m, $0.sequence) }
        return m
    }

    /// Splits a log file into its logical records, reassembling fragments across 32 KiB blocks and
    /// verifying each fragment's checksum.
    static func logRecords(_ bytes: [UInt8], tolerateTornTail: Bool) throws -> [[UInt8]] {
        let blockSize = 32768, header = 7
        var out = [[UInt8]]()
        var pending: [UInt8]?
        var pos = 0
        while pos < bytes.count {
            let left = blockSize - pos % blockSize
            if left < header { pos += left; continue }   // block trailer padding
            if pos + header > bytes.count {
                if bytes[pos...].allSatisfy({ $0 == 0 }) { break }
                if tolerateTornTail { return out }
                throw fail()
            }
            let len = Int(bytes[pos + 4]) | Int(bytes[pos + 5]) << 8
            let type = bytes[pos + 6]
            if type == 0 && len == 0 { pos += left; continue }   // zero-filled space
            guard header + len <= left else { throw fail() }
            let end = pos + header + len
            if end > bytes.count {
                if tolerateTornTail { return out }
                throw fail()
            }
            let stored = UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
            let payload = Array(bytes[(pos + header)..<end])
            let crc = CRC32C.masked(CRC32C.checksum(payload, seed: CRC32C.checksum([type])))
            if crc != stored {
                if tolerateTornTail && end >= bytes.count { return out }
                throw fail()
            }
            switch type {
            case 1:
                guard pending == nil else { throw fail() }
                out.append(payload)
            case 2:
                guard pending == nil else { throw fail() }
                pending = payload
            case 3:
                guard pending != nil else { throw fail() }
                pending!.append(contentsOf: payload)
            case 4:
                guard let p = pending else { throw fail() }
                out.append(p + payload)
                pending = nil
            default:
                throw fail()
            }
            pos = end
        }
        if pending != nil {
            if tolerateTornTail { return out }
            throw fail()
        }
        return out
    }

    // MARK: Scanning

    private static func fileName(_ number: UInt64, _ ext: String) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits + "." + ext
    }

    /// Calls `visit` for every record in the live tables and in the logs that are still current.
    private func scan(_ visit: (LevelDBEntry) -> Void) throws {
        let m = try manifest()
        for number in m.liveTables {
            let ldb = folder.appendingPathComponent(Self.fileName(number, "ldb"))
            let sst = folder.appendingPathComponent(Self.fileName(number, "sst"))
            guard let data = (try? Data(contentsOf: ldb)) ?? (try? Data(contentsOf: sst)) else { throw Self.fail() }
            try Self.readTable([UInt8](data), visit)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var logs = [(UInt64, String)]()
        for name in names where name.hasSuffix(".log") {
            guard let n = UInt64(name.dropLast(4)) else { continue }
            if n >= m.logNumber || (m.prevLogNumber != 0 && n == m.prevLogNumber) { logs.append((n, name)) }
        }
        for (_, name) in logs.sorted(by: { $0.0 < $1.0 }) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { throw Self.fail() }
            for batch in try Self.logRecords([UInt8](data), tolerateTornTail: tolerateTornTail) {
                try Self.readBatch(batch, visit)
            }
        }
    }

    /// A write batch: 8-byte first sequence, 4-byte count, then put (1) / delete (0) operations.
    private static func readBatch(_ batch: [UInt8], _ visit: (LevelDBEntry) -> Void) throws {
        guard batch.count >= 12 else { throw fail() }
        var c = Cursor(batch)
        let seq = UInt64(try c.fixed(8)), count = try c.fixed(4)
        for n in 0..<count {
            let op = try c.fixed(1)
            let key = try c.lengthPrefixed()
            switch op {
            case 1: visit(LevelDBEntry(key: Data(key), sequence: seq + n, isPut: true, value: Data(try c.lengthPrefixed())))
            case 0: visit(LevelDBEntry(key: Data(key), sequence: seq + n, isPut: false, value: Data()))
            default: throw fail()
            }
        }
        guard c.atEnd else { throw fail() }
    }

    private static func readTable(_ file: [UInt8], _ visit: (LevelDBEntry) -> Void) throws {
        guard file.count >= 48 else { throw fail() }
        var footer = Cursor(Array(file[(file.count - 48)...]))
        _ = try footer.varint(); _ = try footer.varint()   // metaindex handle: unused
        let indexHandle = (try footer.varint(), try footer.varint())
        var magic = Cursor(Array(file[(file.count - 8)...]))
        guard try magic.fixed(8) == 0xdb4775248b80fb57 else { throw fail() }

        for (_, handle) in try blockEntries(try readBlock(file, indexHandle.0, indexHandle.1)) {
            var h = Cursor(handle)
            let block = try readBlock(file, try h.varint(), try h.varint())
            for (internalKey, value) in try blockEntries(block) {
                guard internalKey.count >= 8 else { throw fail() }
                var t = Cursor(Array(internalKey[(internalKey.count - 8)...]))
                let tag = try t.fixed(8)
                let kind = tag & 0xFF
                guard kind <= 1 else { throw fail() }
                visit(LevelDBEntry(key: Data(internalKey[..<(internalKey.count - 8)]), sequence: tag >> 8,
                                   isPut: kind == 1, value: Data(value)))
            }
        }
    }

    /// A block's contents after verifying its checksum and undoing compression.
    private static func readBlock(_ file: [UInt8], _ offset: UInt64, _ size: UInt64) throws -> [UInt8] {
        guard offset <= UInt64(file.count), size <= UInt64(file.count), Int(offset) + Int(size) + 5 <= file.count else { throw fail() }
        let start = Int(offset), end = start + Int(size)
        let contents = Array(file[start..<end])
        let type = file[end]
        let stored = UInt32(file[end + 1]) | UInt32(file[end + 2]) << 8 | UInt32(file[end + 3]) << 16 | UInt32(file[end + 4]) << 24
        guard CRC32C.masked(CRC32C.checksum([type], seed: CRC32C.checksum(contents))) == stored else { throw fail() }
        switch type {
        case 0: return contents
        case 1: return try Snappy.decompress(contents)
        default: throw fail()
        }
    }

    /// Decodes a block's prefix-compressed (key, value) entries; the restart array is only bounds-checked.
    private static func blockEntries(_ block: [UInt8]) throws -> [([UInt8], [UInt8])] {
        guard block.count >= 4 else { throw fail() }
        var tail = Cursor(Array(block[(block.count - 4)...]))
        let restarts = Int(try tail.fixed(4))
        guard restarts <= (block.count - 4) / 4 else { throw fail() }
        var c = Cursor(Array(block[..<(block.count - 4 - 4 * restarts)]))
        var key = [UInt8](), out = [([UInt8], [UInt8])]()
        while !c.atEnd {
            let shared = try c.varint(), nonShared = try c.varint(), valueLength = try c.varint()
            guard shared <= UInt64(key.count) else { throw fail() }
            key = Array(key[..<Int(shared)]) + (try c.take(nonShared))
            out.append((key, try c.take(valueLength)))
        }
        return out
    }

    /// Bounds-checked reader over a byte array.
    private struct Cursor {
        let bytes: [UInt8]
        var pos = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var atEnd: Bool { pos >= bytes.count }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 70 {
                guard pos < bytes.count else { throw LevelDBReader.fail() }
                let b = bytes[pos]; pos += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            throw LevelDBReader.fail()
        }

        mutating func take(_ n: UInt64) throws -> [UInt8] {
            guard n <= UInt64(bytes.count - pos) else { throw LevelDBReader.fail() }
            defer { pos += Int(n) }
            return Array(bytes[pos..<(pos + Int(n))])
        }

        mutating func lengthPrefixed() throws -> [UInt8] { try take(try varint()) }

        /// Little-endian integer of `width` bytes (1...8).
        mutating func fixed(_ width: Int) throws -> UInt64 {
            let b = try take(UInt64(width))
            var v: UInt64 = 0
            for (i, x) in b.enumerated() { v |= UInt64(x) << (8 * UInt64(i)) }
            return v
        }
    }
}
