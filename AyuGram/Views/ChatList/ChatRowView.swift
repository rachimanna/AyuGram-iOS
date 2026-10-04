import SwiftUI
import UIKit

/// DialogCell: avatar, title, time, two-line preview, counters, read checks.
struct ChatRowView: View {
    let chat: ChatItem
    let preview: (prefix: String?, text: String, isFiltered: Bool, isDraft: Bool)
    var isPinned: Bool = false

    @Environment(TelegramService.self) private var service

    private var isSaved: Bool { if case .savedMessages = chat.kind { return true }; return false }

    private var title: String { isSaved ? L("SavedMessages") : chat.title }

    private var isOnline: Bool {
        guard let uid = chat.kind.privateUserId, !isSaved, case .online = service.users[uid]?.status else { return false }
        return true
    }

    var body: some View {
        let unread = chat.visibleUnreadCount(localReadUntil: LocalReadStore.shared.readUntil(chatId: chat.id))
        HStack(alignment: .center, spacing: 12) {
            AvatarView(id: chat.id, title: title, photo: chat.photo, size: 56, colorId: chat.accentColorId, isSavedMessages: isSaved)
                .overlay(alignment: .bottomTrailing) {
                    if isOnline {
                        Circle().fill(Color.green)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2.5))
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    kindIcon
                    Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if chat.isVerified || isVerified { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.tint) }
                    if isPremiumUser { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.purple) }
                    if chat.isMuted { Image(systemName: "speaker.slash.fill").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    outgoingStatus
                    Text(Formatters.chatListTime(chat.lastMessage?.date ?? 0))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 6) {
                    previewText
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    badges(unread: unread)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var isVerified: Bool {
        switch chat.kind {
        case .supergroup(let id), .channel(let id): return service.supergroups[id]?.isVerified ?? false
        case .user(let uid), .bot(let uid): return service.users[uid]?.isVerified ?? false
        default: return false
        }
    }

    /// Premium star next to premium users (Telegram DialogCell).
    private var isPremiumUser: Bool {
        guard let uid = chat.kind.privateUserId, !isSaved else { return false }
        return service.users[uid]?.isPremium == true
    }

    @ViewBuilder
    private var kindIcon: some View {
        switch chat.kind {
        case .secret: Image(systemName: "lock.fill").font(.caption).foregroundStyle(.green)
        case .channel: Image(systemName: "megaphone.fill").font(.caption).foregroundStyle(.secondary)
        case .basicGroup, .supergroup: Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.secondary)
        case .bot: Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var outgoingStatus: some View {
        if let last = chat.lastMessage, last.isOutgoing, !last.body.isService {
            switch last.sendingState {
            case .pending: Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
            case .failed: Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
            case .sent:
                let read = chat.lastReadOutboxMessageId >= last.id || isSaved
                Image(systemName: read ? "checkmark.circle.fill" : "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
    }

    private var previewText: Text {
        var result = Text("")
        if let prefix = preview.prefix {
            result = Text(prefix + ": ").foregroundColor(preview.isDraft ? .red : .primary)
        }
        if service.chatActions[chat.id] != nil {
            return Text(preview.text).foregroundColor(.accentColor)
        }
        return result + Text(preview.text)
    }

    @ViewBuilder
    private func badges(unread: Int) -> some View {
        HStack(spacing: 4) {
            if chat.unreadMentionCount > 0 {
                Text("@").font(.caption.bold()).foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(.tint, in: Circle())
            }
            if unread > 0 || chat.isMarkedAsUnread {
                Text(unread > 0 ? Formatters.compactCount(unread) : " ")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(chat.isMuted ? AnyShapeStyle(Color.gray) : AnyShapeStyle(.tint), in: Capsule())
            } else if isPinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).rotationEffect(.degrees(45))
            }
        }
    }
}
