import SwiftUI
import SwitcherCore

/// How one account's copy of a chat reads, in the app's language (English on the command line).
enum SharedChatsText {
    static func status(_ s: CopyStatus) -> String {
        switch s {
        case .latest: return L("up to date", "güncel")
        case .behind(let n): return L("\(n) messages behind", "\(n) mesaj geride")
        case .forked(let n): return L("forked, \(n) messages of its own", "çatallanmış, kendine ait \(n) mesaj")
        case .noTranscript: return L("no history", "geçmiş yok")
        case .willSplit: return L("same history, but will split when resumed here", "aynı geçmiş, ama burada sürdürülünce ayrışacak")
        // Worded properly with the linking feature; neutral until then.
        case .linkBroken, .archivedHereOnly: return L("needs attention", "dikkat gerekiyor")
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
    var refresh: () -> Void = {}
    var openAccount: (String) -> Void = { _ in }
}

/// Chats that exist in more than one account, and how far each account's copy has got.
struct SharedChatsView: View {
    @ObservedObject var model: SharedChatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Chats in more than one account", "Birden fazla hesapta olan sohbetler")).font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
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
                            SharedChatRow(chat: chat, openAccount: model.openAccount)
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
    let openAccount: (String) -> Void
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
                    Text(SharedChatsText.status(status)).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            if chat.diverged, let best = SharedChatsText.upToDateCopy(of: chat) {
                HStack {
                    Button(L("Open where it's up to date", "En güncel olduğu hesapta aç")) {
                        opened = true
                        openAccount(best.profileID)
                    }
                    if opened {
                        Text(L("Open '\(chat.title)' in this account", "Bu hesapta '\(chat.title)' sohbetini açın"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(chat.diverged ? 0.08 : 0.04)))
    }
}
