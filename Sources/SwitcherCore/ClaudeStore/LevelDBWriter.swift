import Foundation

/// Exclusive hold on a LevelDB folder's `LOCK` file, the same `fcntl` lock Chromium takes while it has the
/// database open. Succeeding means no process has the database open.
enum LevelDBLock {
    static func withExclusive<T>(_ folder: URL, _ body: () throws -> T) throws -> T {
        let fd = open(folder.appendingPathComponent("LOCK").path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else {
            throw SwitcherError("Claude's local data is not in the expected format.", logReason: "leveldb lock missing")
        }
        defer { close(fd) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)   // l_start and l_len stay 0: the whole file
        guard fcntl(fd, F_SETLK, &lock) == 0 else {
            throw SwitcherError(L("Claude is using this account's data; quit it first.",
                                  "Claude bu hesabın verisini kullanıyor; önce kapatın."), logReason: "store is locked")
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = fcntl(fd, F_SETLK, &lock)
        }
        return try body()
    }
}

/// Appends one write batch to the current write-ahead log of a closed LevelDB database, the way LevelDB
/// itself would. The caller holds `LevelDBLock`. Refuses unless the whole log verifies and ends cleanly.
struct LevelDBWriter {
    let folder: URL

    init(folder: URL) { self.folder = folder }

    private static let blockSize = 32768, headerSize = 7
    /// Sequence numbers share a 64-bit tag with an 8-bit kind, so they must stay below 2^56.
    private static let sequenceLimit: UInt64 = 1 << 56

    private static func notClean() -> SwitcherError {
        SwitcherError("Claude's local data is not in the expected format.", logReason: "leveldb log not clean")
    }

    /// Writes `puts` as one batch and returns the sequence number of its first put.
    func append(_ puts: [(key: Data, value: Data)]) throws -> UInt64 {
        guard !puts.isEmpty, puts.count <= Int(UInt32.max) else { throw Self.notClean() }
        let reader = LevelDBReader(folder: folder)
        let url = try reader.currentLogURL()
        try requireSingleLiveLog(logNumber: try reader.manifest().logNumber)
        guard let existing = try? Data(contentsOf: url) else {
            throw SwitcherError("Claude's local data is not in the expected format.", logReason: "leveldb current log missing")
        }
        _ = try LevelDBReader.logRecords([UInt8](existing), tolerateTornTail: false)   // every checksum
        let size = existing.count
        try Self.requireCleanEnd(existing)

        let (seq, overflow) = try reader.maxSequence().addingReportingOverflow(1)
        let (last, overflow2) = seq.addingReportingOverflow(UInt64(puts.count - 1))
        guard !overflow, !overflow2, last < Self.sequenceLimit else { throw Self.notClean() }

        var batch = Encoding.le(seq, 8) + Encoding.le(UInt64(puts.count), 4)
        for p in puts {
            batch.append(1)
            batch += Encoding.varint(UInt64(p.key.count)) + p.key
            batch += Encoding.varint(UInt64(p.value.count)) + p.value
        }
        let bytes = Self.frame(batch, startingAt: size)

        let fd = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { throw Self.notClean() }
        defer { close(fd) }
        var written = 0
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            while written < bytes.count {
                let n = write(fd, raw.baseAddress! + written, bytes.count - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
        // A failed or unsynced write must not leave a half record behind: cut back to the verified end.
        guard ok, fsync(fd) == 0 else {
            _ = ftruncate(fd, off_t(size))
            throw SwitcherError(L("Could not write Claude's local data.", "Claude verisi yazılamadı."), logReason: "leveldb write failed")
        }
        return seq
    }

    /// More than one log at or above the MANIFEST's log number is a state the switcher has not seen: refuse.
    private func requireSingleLiveLog(logNumber: UInt64) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let live = names.filter { name in
            guard name.hasSuffix(".log"), let n = UInt64(name.dropLast(4)) else { return false }
            return n >= logNumber
        }
        guard live.count <= 1 else {
            throw SwitcherError("Claude's local data is not in the expected format.", logReason: "leveldb several live logs")
        }
    }

    /// The file must stop exactly where a record ends, or where block padding (all zeros) completes a block.
    private static func requireCleanEnd(_ file: Data) throws {
        let b = [UInt8](file)
        var pos = 0
        while pos < b.count {
            let left = blockSize - pos % blockSize
            if left < headerSize {
                guard pos + left <= b.count, b[pos..<(pos + left)].allSatisfy({ $0 == 0 }) else { throw notClean() }
                pos += left
                continue
            }
            guard pos + headerSize <= b.count else { throw notClean() }
            let length = Int(b[pos + 4]) | Int(b[pos + 5]) << 8
            guard (1...4).contains(b[pos + 6]), headerSize + length <= left else { throw notClean() }
            pos += headerSize + length
        }
        guard pos == b.count else { throw notClean() }
    }

    /// `payload` as physical log records for a file currently `offset` bytes long.
    private static func frame(_ payload: [UInt8], startingAt offset: Int) -> [UInt8] {
        var out = [UInt8](), rest = payload[...], first = true
        var pos = offset
        repeat {
            let left = blockSize - pos % blockSize
            if left < headerSize {
                out += [UInt8](repeating: 0, count: left)
                pos += left
                continue
            }
            let n = min(rest.count, left - headerSize)
            let isLast = n == rest.count
            let type: UInt8 = first && isLast ? 1 : first ? 2 : isLast ? 4 : 3
            let fragment = Array(rest.prefix(n))
            let crc = CRC32C.masked(CRC32C.checksum(fragment, seed: CRC32C.checksum([type])))
            out += Encoding.le(UInt64(crc), 4) + Encoding.le(UInt64(n), 2) + [type] + fragment
            pos += headerSize + n
            rest = rest.dropFirst(n)
            first = false
        } while !rest.isEmpty
        return out
    }
}

private enum Encoding {
    static func le(_ value: UInt64, _ width: Int) -> [UInt8] { (0..<width).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) } }
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out = [UInt8]()
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        return out + [UInt8(v)]
    }
}
