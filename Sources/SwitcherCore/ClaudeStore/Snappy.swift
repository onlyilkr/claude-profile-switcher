import Foundation

/// Decoder for the raw Snappy block format (varint length, then literal and copy elements).
enum Snappy {
    private static func corrupt() -> SwitcherError {
        SwitcherError("Compressed data is damaged.", logReason: "snappy block corrupt")
    }

    static func decompress(_ bytes: [UInt8]) throws -> [UInt8] {
        var pos = 0
        var expected = 0
        var shift = 0
        while true {
            guard pos < bytes.count, shift <= 28 else { throw corrupt() }
            let b = bytes[pos]; pos += 1
            expected |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        var out = [UInt8]()
        // The declared length is untrusted: don't let a tiny input reserve gigabytes.
        out.reserveCapacity(min(expected, bytes.count * 64))
        while pos < bytes.count {
            let tag = bytes[pos]; pos += 1
            switch tag & 3 {
            case 0:
                var len = Int(tag >> 2)
                if len >= 60 {
                    let extra = len - 59
                    guard pos + extra <= bytes.count else { throw corrupt() }
                    len = 0
                    for i in 0..<extra { len |= Int(bytes[pos + i]) << (8 * i) }
                    pos += extra
                }
                len += 1
                guard pos + len <= bytes.count, out.count + len <= expected else { throw corrupt() }
                out.append(contentsOf: bytes[pos..<(pos + len)])
                pos += len
            default:
                let len: Int, offset: Int
                switch tag & 3 {
                case 1:
                    guard pos < bytes.count else { throw corrupt() }
                    len = 4 + Int((tag >> 2) & 7)
                    offset = (Int(tag >> 5) << 8) | Int(bytes[pos]); pos += 1
                case 2:
                    guard pos + 2 <= bytes.count else { throw corrupt() }
                    len = 1 + Int(tag >> 2)
                    offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8); pos += 2
                default:
                    guard pos + 4 <= bytes.count else { throw corrupt() }
                    len = 1 + Int(tag >> 2)
                    offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8) | (Int(bytes[pos + 2]) << 16) | (Int(bytes[pos + 3]) << 24)
                    pos += 4
                }
                guard offset > 0, offset <= out.count, out.count + len <= expected else { throw corrupt() }
                // Byte by byte: a copy may overlap its own output (offset < len repeats a pattern).
                for _ in 0..<len { out.append(out[out.count - offset]) }
            }
        }
        guard out.count == expected else { throw corrupt() }
        return out
    }
}
