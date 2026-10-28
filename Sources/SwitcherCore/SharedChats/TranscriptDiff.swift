import Foundation

/// How two copies of a chat's history file relate. "Messages" are lines that carry a top-level
/// `uuid`; bookkeeping lines (queue operations, cost state, ...) do not count.
public enum TranscriptRelation: Equatable {
    case identical
    case firstAhead(messages: Int)
    case secondAhead(messages: Int)
    case forked(first: Int, second: Int)
}

public enum TranscriptDiff {
    static let chunkSize = 1 << 20

    /// Copies made by Claude are byte-identical up to the point they diverge, so both files are
    /// streamed in chunks and compared line by line until the first differing complete line; only
    /// the remaining tail lines are parsed. A trailing partial line (no "\n") is ignored.
    public static func compare(_ first: URL, _ second: URL) throws -> TranscriptRelation {
        let a = try LineReader(url: first), b = try LineReader(url: second)
        defer { a.close(); b.close() }
        var lineA = try a.next(), lineB = try b.next()
        while let x = lineA, let y = lineB, x == y {
            lineA = try a.next(); lineB = try b.next()
        }
        let countA = try countMessages(starting: lineA, in: a)
        let countB = try countMessages(starting: lineB, in: b)
        switch (countA, countB) {
        case (0, 0): return .identical
        case (_, 0): return .firstAhead(messages: countA)
        case (0, _): return .secondAhead(messages: countB)
        default: return .forked(first: countA, second: countB)
        }
    }

    /// A valid JSON object with a top-level string field `uuid`.
    public static func isMessageLine(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return object["uuid"] is String
    }

    private static func countMessages(starting line: Data?, in reader: LineReader) throws -> Int {
        var count = 0
        var current = line
        while let l = current {
            if isMessageLine(l) { count += 1 }
            current = try reader.next()
        }
        return count
    }

    /// Yields complete lines (without the "\n") from a file read in chunks.
    private final class LineReader {
        private let handle: FileHandle
        private var buffer = Data()
        private var pos = 0   // buffer always starts at index 0
        private var eof = false

        init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
        func close() { try? handle.close() }

        func next() throws -> Data? {
            while true {
                if let nl = buffer[pos...].firstIndex(of: 0x0A) {
                    let line = Data(buffer[pos..<nl])
                    pos = nl + 1
                    return line
                }
                if eof { return nil }
                // Keep the unfinished tail, then add the next chunk.
                buffer = Data(buffer[pos...])
                pos = 0
                let chunk = try handle.read(upToCount: TranscriptDiff.chunkSize) ?? Data()
                if chunk.isEmpty { eof = true } else { buffer.append(chunk) }
            }
        }
    }
}
