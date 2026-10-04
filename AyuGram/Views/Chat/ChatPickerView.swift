import SwiftUI
import UIKit

/// Chat selection sheet (forwarding).
struct ChatPickerView: View {
    let title: String
    let onPick: (Int64) -> Void

    @Environment(TelegramService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var ids: [Int64] {
        let all = service.sortedChatIds(in: .main)
        guard !query.isEmpty else { return all }
        return all.filter { service.chatTitle($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(ids, id: \.self) { id in
                if let chat = service.chats[id] {
                    Button {
                        onPick(id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(id: id, title: chat.title, photo: chat.photo, size: 40, colorId: chat.accentColorId,
                                       isSavedMessages: chat.isSavedMessages)
                            Text(service.chatTitle(id)).foregroundStyle(.primary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
        }
    }
}

/// All saved deleted messages of a chat (browse the AyuGram database).
struct DeletedMessagesView: View {
    let chatId: Int64

    @Environment(TelegramService.self) private var service
    @State private var messages: [MessageItem] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && messages.isEmpty {
                ContentUnavailableView(L("NoDeletedMessages"), systemImage: "trash.slash", description: Text(L("NoDeletedMessagesHint")))
            }
            ForEach(messages) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(service.nameOf(m.sender)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Formatters.fullDateTime(m.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    MessageContentView(message: m, isOutgoing: false, onMedia: { _ in })
                }
                .swipeActions {
                    Button(role: .destructive) {
                        AyuMessagesController.shared.removeSavedDeleted(chatId: chatId, messageId: m.id)
                        messages.removeAll { $0.id == m.id }
                    } label: { Label(L("Delete"), systemImage: "trash") }
                }
                .contextMenu {
                    if !m.body.plainText.isEmpty {
                        Button { UIPasteboard.general.string = m.body.plainText } label: { Label(L("Copy"), systemImage: "doc.on.doc") }
                    }
                }
            }
        }
        .navigationTitle(L("DeletedMessages"))
        .task {
            messages = await withCheckedContinuation { cont in
                AyuMessagesController.shared.latestDeleted(chatId: chatId, limit: 500) { cont.resume(returning: $0) }
            }
            loaded = true
        }
    }
}
