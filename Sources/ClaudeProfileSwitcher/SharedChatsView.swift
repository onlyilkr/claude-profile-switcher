import SwiftUI
import SwitcherCore

/// How one account's copy of a chat reads, in the app's language (English on the command line).
enum SharedChatsText {
    static func status(_ s: CopyStatus, linked: Bool = false) -> String {
        switch s {
        case .latest: return linked ? L("linked, up to date", "bağlı, güncel") : L("up to date", "güncel")
        case .behind(let n): return L("\(n) messages behind", "\(n) mesaj geride")
        case .forked(let n): return L("forked, \(n) messages of its own", "çatallanmış, kendine ait \(n) mesaj")
        case .noTranscript: return L("no history", "geçmiş yok")
        case .willSplit: return L("same history, but will split when resumed here", "aynı geçmiş, ama burada sürdürülünce ayrışacak")
        case .linkBroken: return L("linked, but Claude moved it again", "bağlı, ama Claude yine taşıdı")
        case .archivedHereOnly:
            return L("linked, archived only here — Claude in this account may give its folder to another chat; archive it in every account or unarchive it here",
                     "bağlı, yalnızca burada arşivli — bu hesaptaki Claude klasörünü başka bir sohbete verebilir; her hesapta arşivleyin ya da burada arşivden çıkarın")
        }
    }

    /// The account holding the history the others are measured against: its copy is up to date.
    static func upToDateCopy(of chat: SharedChat) -> ChatCopy? {
        chat.copies.first { chat.status[$0.profileID] == .latest }
    }
}

final class SharedChatsModel: ObservableObject {
    @Published var chats: [SharedChat] = []
    @Published var loading = false
    /// The experimental linking setting; Sync and Link only show while it is on.
    @Published var linkEnabled = false
    /// A link or unlink is running.
    @Published var busy = false
    var refresh: () -> Void = {}
    var openAccount: (String) -> Void = { _ in }
    var sync: (SharedChat) -> Void = { _ in }
    var link: (SharedChat) -> Void = { _ in }
    var unlink: (SharedChat) -> Void = { _ in }
    var linkAll: () -> Void = {}
}

/// Chats that exist in more than one account, and how far each account's copy has got.
struct SharedChatsView: View {
    @ObservedObject var model: SharedChatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Chats in more than one account", "Birden fazla hesapta olan sohbetler")).font(.headline)
                Spacer()
                if model.loading || model.busy { ProgressView().controlSize(.small) }
                if model.linkEnabled, model.chats.contains(where: LinkPolicy.needsLinking) {
                    Button(L("Link all", "Tümünü bağla")) { model.linkAll() }.disabled(model.busy)
                }
                Button(L("Refresh", "Yenile")) { model.refresh() }.disabled(model.loading)
            }
            if model.chats.isEmpty {
                Text(model.loading ? L("Looking…", "Aranıyor…") : L("No chat exists in more than one account.", "Birden fazla hesapta bulunan sohbet yok."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.chats) { chat in
                            SharedChatRow(chat: chat, model: model)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 240, idealHeight: 380)
    }
}

private struct SharedChatRow: View {
    let chat: SharedChat
    let model: SharedChatsModel
    @State private var opened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(chat.folder).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            ForEach(chat.copies, id: \.profileID) { copy in
                let status = chat.status[copy.profileID] ?? .latest
                HStack(spacing: 6) {
                    Image(systemName: status == .latest ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status == .latest ? Color.green : Color.orange)
                        .font(.system(size: 11))
                    Text(copy.profileName).font(.system(size: 12))
                    Text(SharedChatsText.status(status, linked: chat.isLinked)).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            if chat.diverged, let best = SharedChatsText.upToDateCopy(of: chat) {
                HStack {
                    Button(L("Open where it's up to date", "En güncel olduğu hesapta aç")) {
                        opened = true
                        model.openAccount(best.profileID)
                    }
                    if opened {
                        Text(L("Open '\(chat.title)' in this account", "Bu hesapta '\(chat.title)' sohbetini açın"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
            actions
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(chat.diverged ? 0.08 : 0.04)))
    }
}


private extension SharedChatRow {
    /// Sync for a copy that is behind or forked, Link for one that would split, Unlink once linked.
    @ViewBuilder var actions: some View {
        let sync = model.linkEnabled && (LinkPolicy.isBehind(chat) || LinkPolicy.isForked(chat))
        let link = model.linkEnabled && !sync && !chat.isLinked && LinkPolicy.needsLinking(chat)
        if sync || link || chat.isLinked {
            HStack {
                if sync { Button(L("Sync", "Eşitle")) { model.sync(chat) } }
                if link { Button(L("Link", "Bağla")) { model.link(chat) } }
                if chat.isLinked { Button(L("Unlink", "Bağlantıyı kaldır")) { model.unlink(chat) } }
            }
            .disabled(model.busy)
            .padding(.top, 2)
        }
    }
}
