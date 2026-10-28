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

    /// profileID -> the messages of its own that each non-winner copy had when the chat was scanned, for the
    /// copies the linker may only replace while they still have exactly those: forked copies, and the
    /// up-to-date copy when the user kept a forked copy instead of it. Taken only from the scan, never
    /// from the files now; a copy whose number the scan did not record is left out, and the linker refuses it.
    public static func expectedForks(_ chat: SharedChat, winner: String) -> [String: Int] {
        var out: [String: Int] = [:]
        guard let win = chat.copies.first(where: { $0.profileID == winner }) else { return out }
        let winnerForked = chat.forkCounts[winner] != nil
        for copy in chat.copies where copy.profileID != winner {
            if let fork = chat.forkCounts[copy.profileID] { out[copy.profileID] = fork.other; continue }
            // An up-to-date copy shares the reference's history: its own messages (against the forked winner)
            // are the reference's own messages against that fork.
            if winnerForked, chat.status[copy.profileID] == .latest, copy.hasTranscript, win.hasTranscript,
               copy.transcript != win.transcript, let fork = chat.forkCounts[winner] {
                out[copy.profileID] = fork.reference
            }
        }
        return out
    }

    /// Linked chats whose Claude Code process runs under two or more different account folders.
    public static func openInSeveral(_ chats: [SharedChat], live: [(pid: pid_t, profileDir: String, cliSessionID: String)]) -> [SharedChat] {
        var dirs: [String: Set<String>] = [:]
        for item in live { dirs[item.cliSessionID, default: []].insert(URL(fileURLWithPath: item.profileDir).standardizedFileURL.path) }
        return chats.filter { $0.isLinked && (dirs[$0.cliSessionID]?.count ?? 0) >= 2 }
    }

    /// Only willSplit copies besides the up-to-date ones: safe for "Link all".
    public static func isPlainSplit(_ chat: SharedChat) -> Bool {
        needsLinking(chat) && chat.status.values.allSatisfy { $0 == .latest || $0 == .willSplit }
    }

    /// Ids of linked chats with a copy Claude moved again.
    public static func brokenIDs(_ chats: [SharedChat]) -> Set<String> {
        Set(chats.filter { $0.isLinked && $0.status.values.contains(.linkBroken) }.map(\.id))
    }

    /// A linked chat has a copy Claude moved again.
    public static func hasBroken(_ chats: [SharedChat]) -> Bool {
        chats.contains { $0.isLinked && $0.status.values.contains(.linkBroken) }
    }
}
