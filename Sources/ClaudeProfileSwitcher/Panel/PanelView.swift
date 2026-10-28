import SwiftUI
import SwitcherCore

/// The panel under the menu bar icon. Native materials, system type and colours: the only
/// colour of its own is each account's identity, and the one thing that moves is the ring
/// around an account that is opening.
struct PanelView: View {
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let missing = state.claudeMissing {
                MissingClaudeView(message: missing, actions: state.actions)
            } else {
                header
                if let error = state.errorMessage { ErrorBanner(text: error) { state.errorMessage = nil } }
                if state.showRoutingBanner { RoutingBanner(actions: state.actions) }
                if state.usagePaused && !state.usageNoticeDismissed {
                    UsagePausedNotice(openCount: state.openCount) { state.usageNoticeDismissed = true }
                }
                if state.showSharedChatsNotice {
                    SharedChatsNotice(count: state.divergedChats, show: state.actions.openSharedChats) {
                        state.sharedChatsNoticeDismissedFor = state.divergedChatIDs
                    }
                }
                accounts
                PanelDivider()
                SettingsSection(state: state)
            }
            PanelDivider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L("Claude accounts", "Claude hesapları"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if state.openCount > 0 {
                Text(L("\(state.openCount) open", "\(state.openCount) açık"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var accounts: some View {
        let list = VStack(spacing: 1) {
            ForEach(state.rows) { row in
                if state.deletingID == row.id {
                    DeleteConfirmRow(row: row, state: state)
                } else {
                    AccountRowView(row: row, state: state)
                }
            }
            AddAccountRow(state: state, emphasised: state.rows.count == 1)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)

        // Past seven accounts the list scrolls rather than run off the screen.
        if state.rows.count > 7 {
            ScrollView { list }.frame(height: 7 * 46 + 52)
        } else {
            list
        }
    }

    private var footer: some View {
        HStack {
            if !state.claudeVersion.isEmpty {
                Text("Claude \(state.claudeVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(L("Quit", "Çık")) { state.actions.quit() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help(L("Quit Claude Profile Switcher (⌘Q). Your Claude windows stay open.",
                        "Claude Profile Switcher'dan çık (⌘Q). Claude pencereleriniz açık kalır."))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

// MARK: Rows

struct AccountRowView: View {
    let row: AccountRow
    @ObservedObject var state: PanelState
    @FocusState private var nameFocused: Bool

    private var isRenaming: Bool { state.renamingID == row.id }
    private var isHighlighted: Bool { state.highlighted == row.id && !isRenaming }

    var body: some View {
        HStack(spacing: 10) {
            Avatar(row: row, icon: state.claudeIcon)
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("", text: $state.renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .focused($nameFocused)
                        .onSubmit { state.commitRename() }
                        .onExitCommand { state.cancelEditing() }
                        .onAppear { nameFocused = true }
                    Text(state.renameError ?? L("Return saves, Esc cancels", "Return kaydeder, Esc vazgeçer"))
                        .font(.system(size: 11))
                        .foregroundStyle(state.renameError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(row.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(row.subtitle())
                        .font(.system(size: 11))
                        .foregroundStyle(row.status == .waitingForSignIn ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !isRenaming {
                // The usage meter rests where the ⋯ button appears on hover, so the row
                // never shifts.
                ZStack(alignment: .trailing) {
                    UsageMeter(row: row).opacity(isHighlighted ? 0 : 1)
                    RowMenu(row: row, state: state).opacity(isHighlighted ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Highlight(on: isHighlighted))
        // The meter gives way to the ⋯ button under the pointer, so its detail (the weekly
        // limit, how old the number is) is the whole row's tooltip.
        .help(isRenaming ? "" : row.usageDetail() ?? "")
        .contentShape(Rectangle())
        .onHover { if $0 { state.highlighted = row.id } }
        .onTapGesture { if !isRenaming { state.actions.open(row.id) } }
        .contextMenu { RowMenuItems(row: row, state: state) }
        .help(row.isOpen ? L("Bring '\(row.name)' forward", "'\(row.name)' hesabını öne getir")
                         : L("Open '\(row.name)'", "'\(row.name)' hesabını aç"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(row.name), \(row.subtitle())")
    }
}

struct AddAccountRow: View {
    @ObservedObject var state: PanelState
    /// With only the original account there, adding one is the next step: say so.
    let emphasised: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.6]))
                    .foregroundStyle(emphasised ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 26, height: 26)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(emphasised ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Add account", "Hesap ekle"))
                    .font(.system(size: 13, weight: .medium))
                Text(emphasised ? L("Another account, in its own window", "Başka bir hesap, kendi penceresinde")
                                : L("Opens Claude at a sign-in screen", "Claude'u giriş ekranında açar"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("⌘N")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Highlight(on: state.highlighted == PanelState.addRowID))
        .contentShape(Rectangle())
        .onHover { if $0 { state.highlighted = PanelState.addRowID } }
        .onTapGesture { state.actions.add() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct DeleteConfirmRow: View {
    let row: AccountRow
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Avatar(row: row, icon: state.claudeIcon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Move '\(row.name)' to the Trash?", "'\(row.name)' Çöp Sepeti'ne taşınsın mı?"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L("Its saved sign-in and chat list go with it.", "Kayıtlı girişi ve sohbet listesi de gider."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel", "Vazgeç")) { state.cancelEditing() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Move to Trash", "Çöp Sepeti'ne taşı"), role: .destructive) { state.confirmDelete() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
    }
}

// MARK: Row pieces

/// The account's monogram, or Claude's own icon for the original account, inside a ring
/// that says whether it is open.
struct Avatar: View {
    let row: AccountRow
    let icon: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        ZStack {
            if row.isDefault, let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 26, height: 26)
            } else {
                Circle()
                    .fill(Color(nsColor: Badge.color(index: row.colorIndex)))
                    .frame(width: 26, height: 26)
                Text(row.letter)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            ring
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var ring: some View {
        switch row.status {
        case .open:
            Circle().strokeBorder(Color(nsColor: .systemGreen), lineWidth: 2)
        case .waitingForSignIn:
            Circle().strokeBorder(Color(nsColor: .systemOrange), lineWidth: 2)
        case .opening:
            if reduceMotion {
                Circle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            } else {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(1)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
        case .closed:
            EmptyView()
        }
    }
}

/// The account's 5-hour limit as Claude last measured it: quiet until it matters, orange
/// from 75 %, red from 90 %. For an open account whose Claude has stopped measuring, a dash
/// and an empty track, explained by the notice at the top; nothing for a closed one.
struct UsageMeter: View {
    let row: AccountRow

    var body: some View {
        if row.usagePaused(), let usage = row.usage {
            VStack(alignment: .trailing, spacing: 3) {
                Text(L("–%", "%–"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 34, height: 3)
                Text(usage.age(at: Date()))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.usageDetail() ?? "")
        } else if let session = row.usage?.session(at: Date()) {
            let fraction = min(max(Double(session) / 100, 0), 1)
            let tint: Color = session >= 90 ? Color(nsColor: .systemRed) : session >= 75 ? Color(nsColor: .systemOrange) : .secondary
            VStack(alignment: .trailing, spacing: 3) {
                Text(L("\(session)%", "%\(session)"))
                    .font(.system(size: 11, weight: session >= 75 ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(tint.opacity(session >= 75 ? 1 : 0.7)).frame(width: max(2, 34 * fraction))
                }
                .frame(width: 34, height: 3)
                // Claude measures, the switcher only reads: say how old the number is.
                Text(row.usage!.age(at: Date()))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.usageDetail() ?? "")
        }
    }
}

struct RowMenu: View {
    let row: AccountRow
    @ObservedObject var state: PanelState

    var body: some View {
        Menu {
            RowMenuItems(row: row, state: state)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("More for '\(row.name)'", "'\(row.name)' için diğer işlemler"))
        .accessibilityLabel(L("More for \(row.name)", "\(row.name) için diğer işlemler"))
    }
}

struct RowMenuItems: View {
    let row: AccountRow
    @ObservedObject var state: PanelState

    var body: some View {
        Button(row.isOpen ? L("Bring forward", "Öne getir") : L("Open", "Aç")) { state.actions.open(row.id) }
        Button(L("Open usage in Claude", "Kullanımı Claude'da aç")) { state.actions.openUsage(row.id) }
        Divider()
        Button(L("Rename", "Yeniden adlandır")) { state.beginRename(row.id) }
        Button(L("Transfer Code chats…", "Code sohbetlerini aktar…")) { state.actions.transfer(row.id) }
        Button(row.hasLauncher ? L("Update launcher in Applications", "Uygulamalar'daki başlatıcıyı güncelle")
                               : L("Add launcher to Applications", "Uygulamalar'a başlatıcı ekle")) { state.actions.launcher(row.id) }
        Button(L("Show in Finder", "Finder'da göster")) { state.actions.reveal(row.id) }
        if !row.isDefault {
            Divider()
            let busy = row.isOpen || row.status == .opening
            Button(busy ? L("Quit it to move it to the Trash", "Çöp Sepeti'ne taşımak için önce kapatın")
                        : L("Move to Trash…", "Çöp Sepeti'ne taşı…"), role: .destructive) {
                state.renamingID = nil
                state.deletingID = row.id
            }
            .disabled(busy)
        }
    }
}

struct Highlight: View {
    let on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(on ? Color.primary.opacity(0.08) : Color.clear)
    }
}

// MARK: Settings and banners

struct SettingsSection: View {
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Routing only means something once there is a second account to route to.
            if state.rows.count > 1 || state.routingOn {
                ToggleRow(title: L("Send sign-ins to the right account", "Girişleri doğru hesaba gönder"),
                          detail: L("Browser sign-ins open in the account that asked.", "Tarayıcı girişleri isteyen hesapta açılır."),
                          isOn: Binding(get: { state.routingOn }, set: { state.actions.setRouting($0) }))
            }
            if state.routingOn, state.rows.count > 1 {
                HStack {
                    Text(L("Open other claude:// links in", "Diğer claude:// linklerini aç"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(get: { state.otherLinksID }, set: { state.actions.setOtherLinks($0) })) {
                        ForEach(state.rows) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            if state.rows.count > 1 || state.linkChats {
                ToggleRow(title: L("Keep worktree chats linked across accounts (experimental)", "Worktree sohbetlerini hesaplar arasında bağlı tut (deneysel)"),
                          detail: linkDetail,
                          isOn: Binding(get: { state.linkChats }, set: { state.actions.setLinkChats($0) }))
            }
            ToggleRow(title: L("Open at login", "Oturum açılışında başlat"), detail: nil,
                      isOn: Binding(get: { state.loginItem }, set: { state.actions.setLogin($0) }))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private extension SettingsSection {
    var linkDetail: String {
        var text = L("Same folder and history in every account. Don't use a chat in two accounts at once; deleting it deletes its history everywhere; archive it in every account together. Tried with Claude \(LinkPolicy.testedVersion).",
                     "Her hesapta aynı klasör ve geçmiş. Bir sohbeti iki hesapta aynı anda kullanmayın; silmek geçmişi her yerde siler; arşivlemeyi bütün hesaplarda birlikte yapın. Claude \(LinkPolicy.testedVersion) ile denendi.")
        if !state.claudeVersion.isEmpty, !LinkPolicy.isTested(state.claudeVersion) {
            let v = LinkPolicy.shortVersion(state.claudeVersion)
            text += "\n" + L("Not yet tried with Claude \(v)", "Claude \(v) ile henüz denenmedi")
        }
        return text
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String?
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

/// Shown once there is a second account and nobody has decided about routing yet: the
/// moment it starts to matter, without a dialog in the way of adding the account.
struct RoutingBanner: View {
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Browser sign-ins can open in the wrong account", "Tarayıcı girişleri yanlış hesapta açılabilir"))
                .font(.system(size: 12, weight: .semibold))
            Text(L("Google sign-ins and email links can land in whichever Claude macOS picks. The switcher can send each one to the account that asked.",
                   "Google girişleri ve e-posta linkleri macOS'un seçtiği Claude'a düşebilir. Switcher her girişi isteyen hesaba gönderebilir."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(L("Not now", "Şimdi değil")) { actions.decideRouting(false) }
                Button(L("Turn on", "Aç")) { actions.decideRouting(true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.1)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// Shown while an open account's Claude has stopped measuring usage, so the dashes in the
/// rows are not mistaken for a fault. Claude resumes from its own menu bar menu, which the
/// switcher cannot open for it.
struct UsagePausedNotice: View {
    let openCount: Int
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Claude has paused measuring usage", "Claude kullanım ölçümünü duraklattı"))
                    .font(.system(size: 12, weight: .semibold))
                Text(openCount > 1
                     ? L("It does this when its menu bar icon goes unopened for a while. Each open account has its own Claude icon there: right-click each, and the numbers return in seconds.",
                         "Menü çubuğu simgesi bir süre açılmayınca bunu yapıyor. Her açık hesabın kendi Claude simgesi var: hepsine sağ tıklayın, yüzdeler birkaç saniyede gelir.")
                     : L("It does this when its menu bar icon goes unopened for a while. Right-click Claude's icon in the menu bar, and the number returns in seconds.",
                         "Menü çubuğu simgesi bir süre açılmayınca bunu yapıyor. Menü çubuğundaki Claude simgesine sağ tıklayın, yüzde birkaç saniyede gelir."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("Dismiss", "Kapat"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

struct SharedChatsNotice: View {
    let count: Int
    let show: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text(L("\(count) chats differ between accounts", "\(count) sohbet hesaplar arasında farklı"))
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L("Show", "Göster"), action: show).controlSize(.small)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("Dismiss", "Kapat"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemRed))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("Dismiss", "Kapat"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(0.1)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

struct MissingClaudeView: View {
    let message: String
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Claude is not installed", "Claude kurulu değil"))
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Download Claude", "Claude'u indir")) { actions.downloadClaude() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(16)
    }
}

struct PanelDivider: View {
    var body: some View { Divider().padding(.horizontal, 12) }
}
