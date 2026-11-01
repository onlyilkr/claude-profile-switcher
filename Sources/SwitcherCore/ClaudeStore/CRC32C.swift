import Foundation

/// CRC32C (Castagnoli) as LevelDB uses it for log and table checksums.
enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x82F63B78 : c >> 1 }
        return c
    }

    /// `seed` is a previous checksum, so a record's type byte and payload can be chained.
    static func checksum(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    /// LevelDB stores checksums rotated and offset so a CRC of CRC-bearing data isn't degenerate.
    static func masked(_ crc: UInt32) -> UInt32 {
        ((crc >> 15) | (crc << 17)) &+ 0xA282EAD8
    }
}
