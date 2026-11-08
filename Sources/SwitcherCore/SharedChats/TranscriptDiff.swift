import Foundation

/// How two copies of a chat's history file relate. "Messages" are lines that carry a top-level
/// `uuid`; bookkeeping lines (queue operations, cost state, ...) do not count.
public enum TranscriptRelation: Equatable {
    case identical
    case firstAhead(messages: Int)
    case secondAhead(messages: Int)
    case forked(first: Int, second: Int)

    /// The same relation read the other way round.
    public var flipped: TranscriptRelation {
        switch self {
        case .identical: return .identical
        case .firstAhead(let n): return .secondAhead(messages: n)
        case .secondAhead(let n): return .firstAhead(messages: n)
        case .forked(let a, let b): return .forked(first: b, second: a)
        }
    }
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

    /// `newer` continues `older` under another cliSessionId (Claude resumed the chat and started a new history
    /// file; the new file's record lists the old cliSessionId in priorCliSessionIds). The new file repeats only
    /// part of the old history, and every line carries the new sessionId, so lines can't be compared as they are:
    /// messages are matched by `uuid` instead.
    /// - newer's own messages: those whose uuid the older file doesn't have.
    /// - older's own messages: those after the last message both files have, written once the newer file had
    ///   started its own messages (lines from before the resume, like an interrupted turn, are what was resumed).
    /// The result is read like `compare(older, newer)`: `secondAhead` means the older file is simply behind.
    public static func compareContinuation(older: URL, newer: URL) throws -> TranscriptRelation {
        let old = try messages(in: older), new = try messages(in: newer)
        let oldIDs = Set(old.map(\.uuid)), newIDs = Set(new.map(\.uuid))
        let newOwn = new.filter { !oldIDs.contains($0.uuid) }
        let resumedAt = newOwn.compactMap(\.time).min()
        let lastShared = old.lastIndex { newIDs.contains($0.uuid) } ?? -1
        let oldOwn = old[(lastShared + 1)...].filter { m in
            // A line without a time can't be placed before the resume: it counts as the older file's own.
            guard let resumedAt, let time = m.time else { return true }
            return time >= resumedAt
        }.count
        switch (oldOwn, newOwn.count) {
        case (0, 0): return .identical
        case (_, 0): return .firstAhead(messages: oldOwn)
        case (0, let n): return .secondAhead(messages: n)
        case (let o, let n): return .forked(first: o, second: n)
        }
    }

    private struct Message { let uuid: String; let time: Date? }

    private static func messages(in url: URL) throws -> [Message] {
        let reader = try LineReader(url: url)
        defer { reader.close() }
        var out: [Message] = []
        while let line = try reader.next() {
            // Histories run to hundreds of MB: drain each line's parsed objects right away.
            let message: Message? = autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let uuid = object["uuid"] as? String else { return nil }
                return Message(uuid: uuid, time: (object["timestamp"] as? String).flatMap(parseTime))
            }
            if let message { out.append(message) }
        }
        return out
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()

    static func parseTime(_ text: String) -> Date? { fractional.date(from: text) ?? whole.date(from: text) }

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
