import SwiftUI
import SwitcherCore

/// The panel under the menu bar icon. Native materials, system type and colours: the only
/// colour of its own is each account's identity, and the one thing that moves is the ring
/// around an account that is opening. It opens as a short list of accounts, like a menu; the
/// settings sit in one group below that stays closed until asked for.
struct PanelView: View {
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let missing = state.claudeMissing {
                MissingClaudeView(message: missing, actions: state.actions)
            } else {
                header
                if let error = state.errorMessage { ErrorBanner(text: error) { state.errorMessage = nil } }
                if let version = state.updateAvailable { UpdateNotice(version: version, actions: state.actions) }
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
                AttentionNotes(state: state)
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
                // The dot is the legend of the green ring below.
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: .systemGreen)).frame(width: 6, height: 6)
                    Text(L("\(state.openCount) open", "\(state.openCount) açık"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 7)
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

    /// The switcher's own version (a click opens its release notes) over Claude's, and Quit.
    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                if !state.appVersion.isEmpty {
                    Button { state.actions.openReleaseNotes() } label: {
                        Text(L("Version \(state.appVersion)", "Sürüm \(state.appVersion)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Claude Profile Switcher \(state.appVersion). Click for its release notes.",
                            "Claude Profile Switcher \(state.appVersion). Sürüm notları için tıklayın."))
                }
                if !state.claudeVersion.isEmpty {
                    Text("Claude \(state.claudeVersion)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button { state.actions.quit() } label: {
                HStack(spacing: 6) {
                    Text(L("Quit", "Çık")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("⌘Q").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Quit Claude Profile Switcher. Your Claude windows stay open.",
                    "Claude Profile Switcher'dan çık. Claude pencereleriniz açık kalır."))
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

    private var openLine: String {
        row.isOpen ? L("Bring '\(row.name)' forward", "'\(row.name)' hesabını öne getir")
                   : L("Open '\(row.name)'", "'\(row.name)' hesabını aç")
    }

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
                    RowMenu(row: row, state: state).opacity(isHighlighted ? 1 : 0).allowsHitTesting(isHighlighted)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Highlight(on: isHighlighted))
        .contentShape(Rectangle())
        .onHover { if $0 { state.highlighted = row.id } }
        .onTapGesture { if !isRenaming { state.actions.open(row.id) } }
        .contextMenu { RowMenuItems(row: row, state: state) }
        // One tooltip per row (a second .help on the chain would replace this one): what a
        // click does, then the usage detail the meter gives way to under the pointer.
        .help(isRenaming ? "" : [openLine, row.usageDetail()].compactMap { $0 }.joined(separator: "\n"))
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

/// What the switcher left for the user to look at, always in view (also while Settings is closed):
/// accounts whose chats or pins could not be synced, and chats that still need linking.
struct AttentionNotes: View {
    @ObservedObject var state: PanelState

    private var problems: [PinSyncNote] { state.pinSyncProblems.filter { $0.restoreBlock || state.syncPins } }
    private var linkable: Int { state.linkChats ? state.linkableChats : 0 }

    var body: some View {
        if !problems.isEmpty || linkable > 0 {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(problems) { problem in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .frame(width: 16)
                        Text(problem.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if linkable > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                        Text(linkable == 1 ? L("1 chat isn't linked yet", "1 sohbet henüz bağlı değil")
                                           : L("\(linkable) chats aren't linked yet", "\(linkable) sohbet henüz bağlı değil"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Link all", "Tümünü bağla")) { state.actions.linkAll() }
                            .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }
}

/// One switch of the Settings group. `detail` is the explanation behind the info button.
struct SettingItem: Identifiable {
    let id: String
    let title: String
    /// A short word after the title ("Experimental").
    var tag: String? = nil
    var detail: String? = nil
    let isOn: Binding<Bool>
    /// What belongs to the switch and shows under it (a picker, a warning).
    var extra: AnyView? = nil
}

/// The switches, in one group that stays closed until asked for, so the panel opens as a list of accounts.
/// Each explanation is behind its info button, one open at a time.
struct SettingsSection: View {
    @ObservedObject var state: PanelState
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                state.settingsExpanded.toggle()
                if !state.settingsExpanded { state.expandedInfo = nil }
                state.actions.setSettingsExpanded(state.settingsExpanded)
            } label: {
                HStack {
                    Text(L("Settings", "Ayarlar"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(state.settingsExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Highlight(on: hovering))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .accessibilityLabel(L("Settings", "Ayarlar"))
            .accessibilityValue(state.settingsExpanded ? L("open", "açık") : L("closed", "kapalı"))

            if state.settingsExpanded {
                let items = self.items
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 12) }
                        SettingRow(item: item, state: state)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private var items: [SettingItem] {
        var out: [SettingItem] = []
        // Routing only means something once there is a second account to route to.
        if state.rows.count > 1 || state.routingOn {
            out.append(SettingItem(
                id: "routing", title: L("Send sign-ins to the right account", "Girişleri doğru hesaba gönder"),
                detail: L("Google sign-ins and email links can land in whichever Claude macOS picks. With this on, each one opens in the account that asked.",
                          "Google girişleri ve e-posta linkleri macOS'un seçtiği Claude'a düşebilir. Bu açıkken her giriş, isteyen hesapta açılır."),
                isOn: Binding(get: { state.routingOn }, set: { state.actions.setRouting($0) }),
                extra: state.routingOn && state.rows.count > 1 ? AnyView(otherLinks) : nil))
        }
        if state.rows.count > 1 || !state.syncPins {
            out.append(SettingItem(
                id: "sync", title: L("Sync chats and pins across accounts", "Sohbetleri ve pinleri hesaplar arasında eşitle"),
                detail: L("When an account opens, the chats it shares with the account you used last follow that account: the latest history, archived state, title, deletions and pins in the same order.",
                          "Bir hesap açılırken, en son kullandığınız hesapla ortak sohbetler o hesaba uyar: en yeni geçmiş, arşiv durumu, başlık, silinenler ve aynı sıradaki pinler."),
                isOn: Binding(get: { state.syncPins }, set: { state.actions.setSyncPins($0) })))
        }
        if state.rows.count > 1 || state.linkChats {
            out.append(SettingItem(
                id: "link", title: L("Keep worktree chats linked", "Worktree sohbetlerini bağlı tut"),
                tag: L("Experimental", "Deneysel"),
                detail: L("Same folder and history in every account. Don't use a chat in two accounts at once; deleting it deletes its history everywhere; archive it in every account together. Tried with Claude \(LinkPolicy.testedVersion).",
                          "Her hesapta aynı klasör ve geçmiş. Bir sohbeti iki hesapta aynı anda kullanmayın; silmek geçmişi her yerde siler; arşivlemeyi bütün hesaplarda birlikte yapın. Claude \(LinkPolicy.testedVersion) ile denendi."),
                isOn: Binding(get: { state.linkChats }, set: { state.actions.setLinkChats($0) }),
                extra: untried.map { AnyView(Text($0).font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))) }))
        }
        out.append(SettingItem(
            id: "updates", title: L("Check for updates", "Güncellemeleri denetle"),
            detail: L("Once a day, asks GitHub for the latest release of the switcher. Nothing about your accounts or chats is sent.",
                      "Günde bir kez, switcher'ın en son sürümünü GitHub'a sorar. Hesaplarınız veya sohbetleriniz hakkında hiçbir şey gönderilmez."),
            isOn: Binding(get: { state.checkUpdates }, set: { state.actions.setCheckUpdates($0) })))
        out.append(SettingItem(id: "login", title: L("Open at login", "Oturum açılışında başlat"),
                               isOn: Binding(get: { state.loginItem }, set: { state.actions.setLogin($0) })))
        return out
    }

    /// Linking was tried with one Claude version; say so, in view, when this one is another.
    private var untried: String? {
        guard !state.claudeVersion.isEmpty, !LinkPolicy.isTested(state.claudeVersion) else { return nil }
        let v = LinkPolicy.shortVersion(state.claudeVersion)
        return L("Not yet tried with Claude \(v)", "Claude \(v) ile henüz denenmedi")
    }

    private var otherLinks: some View {
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
}

struct SettingRow: View {
    let item: SettingItem
    @ObservedObject var state: PanelState

    private var showingInfo: Bool { state.expandedInfo == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // Takes all the width the info button and the switch leave, so it wraps only when it must.
                title.frame(maxWidth: .infinity, alignment: .leading)
                if item.detail != nil {
                    Button { state.expandedInfo = showingInfo ? nil : item.id } label: {
                        Image(systemName: showingInfo ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(showingInfo ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.detail ?? "")
                    .accessibilityLabel(L("About \(item.title)", "\(item.title) hakkında"))
                }
                Toggle(item.title, isOn: item.isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if showingInfo, let detail = item.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let extra = item.extra { extra }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }

    private var title: some View {
        var text = Text(item.title).font(.system(size: 13))
        if let tag = item.tag {
            text = text + Text("  " + tag).font(.system(size: 11, weight: .medium)).foregroundColor(Color(nsColor: .systemOrange))
        }
        return text.fixedSize(horizontal: false, vertical: true)
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
        .noticeBox(Color.accentColor.opacity(0.1))
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
            DismissButton(action: dismiss)
        }
        .noticeBox()
    }
}

/// A newer release is out. **Update** upgrades a Homebrew install in Terminal, or opens the release page; the
/// cross hides the note until the next release.
struct UpdateNotice: View {
    let version: String
    let actions: PanelActions

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text(L("Version \(version) is available", "Sürüm \(version) çıktı"))
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L("Update", "Güncelle"), action: actions.update)
                .controlSize(.small)
                .help(L("Updates Claude Profile Switcher to \(version)", "Claude Profile Switcher'ı \(version) sürümüne günceller"))
            DismissButton(action: actions.dismissUpdate)
        }
        .noticeBox(Color.accentColor.opacity(0.1))
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
            DismissButton(action: dismiss)
        }
        .noticeBox()
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
            DismissButton(action: dismiss)
        }
        .noticeBox(Color.red.opacity(0.1))
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

/// The one look of everything the panel says above the accounts.
extension View {
    func noticeBox(_ fill: Color = Color.primary.opacity(0.06)) -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }
}

struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(L("Dismiss", "Kapat"))
    }
}

struct PanelDivider: View {
    var body: some View { Divider().padding(.horizontal, 12) }
}
