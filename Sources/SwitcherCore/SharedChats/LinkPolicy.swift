import Foundation

/// The decisions around linking that need no screen: which copy wins, which rows get which
/// action, and when a linked chat is in trouble.
public enum LinkPolicy {
    /// Claude's `major.minor` the linking was tried with.
    public static let testedVersion = "4.29"

    /// "4.29.0" -> "4.29".
    public static func shortVersion(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    public static func isTested(_ version: String) -> Bool { shortVersion(version) == testedVersion }

    /// A copy that already has a worktree entry that would be split by resuming it.
    public static func needsLinking(_ chat: SharedChat) -> Bool {
        chat.status.values.contains(.willSplit)
    }

    public static func isBehind(_ chat: SharedChat) -> Bool {
        chat.status.values.contains { if case .behind = $0 { return true } else { return false } }
    }

    public static func isForked(_ chat: SharedChat) -> Bool {
        chat.status.values.contains { if case .forked = $0 { return true } else { return false } }
    }

    /// Copies a user may keep when the history has forked: the furthest one and the forked ones.
    public static func forkChoices(_ chat: SharedChat) -> [ChatCopy] {
        chat.copies.filter {
            switch chat.status[$0.profileID] {
            case .latest?, .forked?: return true
            default: return false
            }
        }
    }

    /// The copy the others are brought to: the up-to-date one, preferring the one that holds the
    /// worktree lease; a chat with no up-to-date copy falls back to a copy that would split.
    public static func winner(of chat: SharedChat) -> String? {
        let candidates = chat.copies.filter { chat.status[$0.profileID] == .latest }
        let pool = candidates.isEmpty ? chat.copies.filter { chat.status[$0.profileID] == .willSplit } : candidates
        return (pool.first { $0.leaseHeld == true } ?? pool.first)?.profileID
    }

    /// Linked chats whose Claude Code process runs under two or more different account folders.
    public static func openInSeveral(_ chats: [SharedChat], live: [(pid: pid_t, profileDir: String, cliSessionID: String)]) -> [SharedChat] {
        var dirs: [String: Set<String>] = [:]
        for item in live { dirs[item.cliSessionID, default: []].insert(URL(fileURLWithPath: item.profileDir).standardizedFileURL.path) }
        return chats.filter { $0.isLinked && (dirs[$0.cliSessionID]?.count ?? 0) >= 2 }
    }

    /// A linked chat has a copy Claude moved again.
    public static func hasBroken(_ chats: [SharedChat]) -> Bool {
        chats.contains { $0.isLinked && $0.status.values.contains(.linkBroken) }
    }
}
