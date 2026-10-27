import SwiftUI
import SwitcherCore

/// Pick Claude Code chats of one account and the account to copy them to.
struct TransferView: View {
    let sourceName: String
    let sessions: [CodeSession]
    let targets: [Profile]
    let onCancel: () -> Void
    let onCopy: ([CodeSession], Profile) -> Void

    @State private var selected: Set<String> = []
    @State private var targetID: String

    init(sourceName: String, sessions: [CodeSession], targets: [Profile],
         onCancel: @escaping () -> Void, onCopy: @escaping ([CodeSession], Profile) -> Void) {
        self.sourceName = sourceName
        self.sessions = sessions
        self.targets = targets
        self.onCancel = onCancel
        self.onCopy = onCopy
        _targetID = State(initialValue: targets.first?.id ?? "")
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Chats in '\(sourceName)'", "'\(sourceName)' sohbetleri")).font(.headline)
                Spacer()
                Toggle(L("Select all", "Tümünü seç"), isOn: Binding(
                    get: { !sessions.isEmpty && selected.count == sessions.count },
                    set: { selected = $0 ? Set(sessions.map(\.id)) : [] }))
                    .toggleStyle(.checkbox)
            }
            List(sessions) { s in
                Toggle(isOn: Binding(
                    get: { selected.contains(s.id) },
                    set: { if $0 { selected.insert(s.id) } else { selected.remove(s.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).lineLimit(1)
                        Text(detail(s)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 260)
            HStack {
                Picker(L("Copy to", "Hedef"), selection: $targetID) {
                    ForEach(targets, id: \.id) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 280)
                Spacer()
                Button(L("Cancel", "Vazgeç"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Copy chats", "Sohbetleri kopyala")) {
                    guard let target = targets.first(where: { $0.id == targetID }) else { return }
                    onCopy(sessions.filter { selected.contains($0.id) }, target)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            Text(L("The chat stays in this account too, and pinned chats stay pinned, in the same order. The target account must have opened the Code tab once.",
                   "Sohbet bu hesapta da kalır; pinli sohbetler aynı sırayla pinli kalır. Hedef hesabın Code sekmesini en az bir kez açmış olması gerekir."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 440)
    }

    private func detail(_ s: CodeSession) -> String {
        var parts = [TransferView.dateFormat.string(from: s.updated)]
        if !s.folder.isEmpty { parts.insert(s.folder, at: 0) }
        if !s.hasTranscript { parts.append(L("no transcript on this Mac, opens empty", "bu Mac'te dökümü yok, boş açılır")) }
        return parts.joined(separator: " · ")
    }
}
