import Foundation

/// How long the command line keeps the claude:// handler while Claude starts.
public enum RetakeWait {
    public static let limit: TimeInterval = 20
    public static let settle: TimeInterval = 3

    public static func done(start: Date, lastRetake: Date?, now: Date) -> Bool {
        if now.timeIntervalSince(start) >= limit { return true }
        if let lastRetake { return now.timeIntervalSince(lastRetake) >= settle }
        return false
    }
}
