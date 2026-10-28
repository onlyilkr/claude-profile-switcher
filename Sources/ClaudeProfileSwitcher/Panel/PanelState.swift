import AppKit
import SwitcherCore

/// One account as the panel shows it.
struct AccountRow: Identifiable, Equatable {
    enum Status: Equatable { case open, waitingForSignIn, opening, closed }

    let id: String
    let name: String
    let isDefault: Bool
    let status: Status
    let signedIn: Bool?
    let lastUsed: Date?
    let colorIndex: Int
    let hasLauncher: Bool
    var usage: PlanUsage? = nil

    var letter: String { Badge.letter(for: name) }

    /// "5-hour limit 62%, weekly 30%. Measured by Claude 12 minutes ago."
    func usageDetail(now: Date = Date()) -> String? {
        guard let usage else { return nil }
        if !usage.isCurrent(at: now) {
            guard isOpen else { return nil }
            return L("No measurement in the last 5 hours; Claude last measured this account ",
                     "Son 5 saatte ölçüm yok; Claude bu hesabı en son ") + AccountRow.relative(usage.measuredAt, now: now)
                + L(". Right-click Claude's icon in the menu bar to measure again.", " ölçtü. Yeniden ölçmesi için menü çubuğundaki Claude simgesine sağ tıklayın.")
        }
        var parts: [String] = []
        if let s = usage.session(at: now) { parts.append(L("5-hour limit \(s)%", "5 saatlik limit %\(s)")) }
        if let w = usage.weekly(at: now) { parts.append(L("weekly \(w)%", "haftalık %\(w)")) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ") + ". "
            + L("Measured by Claude ", "Claude'un ölçümü, ") + AccountRow.relative(usage.measuredAt, now: now) + ". "
            + L("For live numbers and reset times: ⋯ > Open usage in Claude.", "Canlı rakamlar ve sıfırlanma saatleri için: ⋯ > Kullanımı Claude'da aç.")
    }
    var isOpen: Bool { status == .open || status == .waitingForSignIn }

    /// Open, yet Claude has not measured it for longer than a 5-hour window: Claude stops
    /// measuring in the background when its own menu bar icon has not been opened for a
    /// while (a day, set by Anthropic), and opening that menu starts it again.
    func usagePaused(now: Date = Date()) -> Bool {
        guard isOpen, let usage else { return false }
        return !usage.isCurrent(at: now)
    }

    func subtitle(now: Date = Date()) -> String {
        switch status {
        case .opening: return L("Opening…", "Açılıyor…")
        case .open: return L("Open", "Açık")
        case .waitingForSignIn: return L("Open, waiting for sign-in", "Açık, giriş bekleniyor")
        case .closed:
            if lastUsed == nil { return L("Never opened", "Hiç açılmadı") }
            if signedIn == false { return L("Not signed in", "Giriş yapılmamış") }
            return L("Last used ", "Son kullanım ") + AccountRow.relative(lastUsed!, now: now)
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return L("just now", "az önce") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: Lang.turkish ? "tr_TR" : "en_US")
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// What the panel's buttons do. Filled in by the app; empty in previews.
struct PanelActions {
    var open: (String) -> Void = { _ in }
    /// Claude's own Settings > Usage for that account: live numbers and reset times.
    var openUsage: (String) -> Void = { _ in }
    var add: () -> Void = {}
    /// nil when renamed, otherwise why not.
    var rename: (String, String) -> String? = { _, _ in nil }
    var delete: (String) -> String? = { _ in nil }
    var transfer: (String) -> Void = { _ in }
    var launcher: (String) -> Void = { _ in }
    var reveal: (String) -> Void = { _ in }
    var setRouting: (Bool) -> Void = { _ in }
    var setLogin: (Bool) -> Void = { _ in }
    var setOtherLinks: (String) -> Void = { _ in }
    var decideRouting: (Bool) -> Void = { _ in }
    var openSharedChats: () -> Void = {}
    var setLinkChats: (Bool) -> Void = { _ in }
    var linkAll: () -> Void = {}
    var setSyncPins: (Bool) -> Void = { _ in }
    var quit: () -> Void = {}
    var downloadClaude: () -> Void = {}
}

final class PanelState: ObservableObject {
    static let addRowID = "\u{0}add"

    @Published var rows: [AccountRow] = []
    @Published var claudeIcon: NSImage?
    @Published var claudeVersion = ""
    @Published var claudeMissing: String?

    @Published var routingOn = false
    @Published var otherLinksID = Profile.defaultID
    @Published var loginItem = false
    @Published var linkChats = false
    @Published var syncPins = true
    @Published var showRoutingBanner = false
    @Published var errorMessage: String?
    /// Hidden until every open account is measured again, then shown the next time.
    @Published var usageNoticeDismissed = false

    /// Chats that differ between accounts, from the last scan (never from the 1.5 s refresh).
    @Published var divergedChats = 0
    @Published var divergedChatIDs: Set<String> = []
    /// The set of differing chats the user closed the notice for; it comes back when the set changes.
    @Published var sharedChatsNoticeDismissedFor: Set<String> = []
    var showSharedChatsNotice: Bool { divergedChats > 0 && sharedChatsNoticeDismissedFor != divergedChatIDs }
    /// Chats that would split and need no choice, from the same scan: what **Link all** links.
    @Published var linkableChats = 0

    /// Hover and the arrow keys move one highlight, as in a menu.
    @Published var highlighted: String?
    @Published var renamingID: String?
    @Published var renameText = ""
    @Published var renameError: String?
    @Published var deletingID: String?

    var actions = PanelActions()

    var openCount: Int { rows.filter(\.isOpen).count }
    var usagePaused: Bool { rows.contains { $0.usagePaused() } }

    /// Rows the arrow keys walk through, the add row last.
    var navigableIDs: [String] { rows.map(\.id) + [PanelState.addRowID] }

    func moveHighlight(_ step: Int) {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        let current = highlighted.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        highlighted = ids[min(max(current + step, 0), ids.count - 1)]
    }

    func activateHighlight() {
        guard let id = highlighted else { return }
        if id == PanelState.addRowID { actions.add() } else { actions.open(id) }
    }

    func beginRename(_ id: String) {
        deletingID = nil
        renameError = nil
        renameText = rows.first { $0.id == id }?.name ?? ""
        renamingID = id
    }

    func commitRename() {
        guard let id = renamingID else { return }
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == rows.first(where: { $0.id == id })?.name { cancelEditing(); return }
        if let problem = actions.rename(id, text) { renameError = problem } else { cancelEditing() }
    }

    func confirmDelete() {
        guard let id = deletingID else { return }
        if let problem = actions.delete(id) { errorMessage = problem }
        deletingID = nil
    }

    func cancelEditing() {
        renamingID = nil
        renameError = nil
        deletingID = nil
    }
}
