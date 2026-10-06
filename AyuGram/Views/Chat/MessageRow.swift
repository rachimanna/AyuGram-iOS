import QuickLook
import SwiftUI

enum MediaViewerItem: Identifiable {
    case photo(PhotoItem)
    case video(VideoItem)

    var id: Int {
        switch self {
        case .photo(let p): return p.file.id
        case .video(let v): return v.file.id
        }
    }
}

/// ChatMessageCell.
struct MessageRow: View {
    let message: MessageItem
    let chat: ChatItem?
    let isRead: Bool
    let model: ChatViewModel
    let onMedia: (MediaViewerItem) -> Void

    @Environment(TelegramService.self) private var service

    private var isGroup: Bool { chat?.kind.isGroup ?? false }
    private var showSender: Bool { isGroup && !message.isOutgoing }

    var body: some View {
        if message.body.isService {
            ServiceMessageView(text: MessagePreview.text(for: message.body), deleted: message.ayuDeleted)
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                if message.isOutgoing { Spacer(minLength: 48) }
                if showSender {
                    AvatarView(id: message.sender.id, title: service.nameOf(message.sender), photo: senderPhoto, size: 32)
                }
                MessageBubble(message: message, chat: chat, isRead: isRead, showSender: showSender, model: model, onMedia: onMedia)
                if !message.isOutgoing { Spacer(minLength: 48) }
            }
            .padding(.vertical, 1)
        }
    }

    private var senderPhoto: PhotoRef? {
        switch message.sender {
        case .user(let id): return service.users[id]?.photo
        case .chat(let id): return service.chats[id]?.photo
        }
    }
}

struct ServiceMessageView: View {
    let text: String
    var deleted: Bool = false

    var body: some View {
        Text(deleted ? "\(AyuConfig.shared.deletedMarkText) \(text)" : text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

struct MessageBubble: View {
    let message: MessageItem
    let chat: ChatItem?
    let isRead: Bool
    let showSender: Bool
    let model: ChatViewModel
    let onMedia: (MediaViewerItem) -> Void

    @Environment(TelegramService.self) private var service
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(AyuConfig.self) private var ayu

    private var isBare: Bool {
        switch message.body {
        case .sticker, .animatedEmoji, .videoNote, .dice: return true
        default: return false
        }
    }

    private var isMediaOnly: Bool {
        switch message.body {
        case .photo(_, let c), .video(_, let c), .animation(_, let c): return c.isEmpty
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showSender && !isBare {
                Text(service.nameOf(message.sender))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.nameColor(for: message.sender.id))
                    .padding(.horizontal, isMediaOnly ? 8 : 0)
                    .padding(.top, isMediaOnly ? 6 : 0)
            }
            if let fwd = message.forwardedFrom {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("ForwardedMessage")).font(.caption)
                    Text(fwd).font(.caption.weight(.semibold))
                }
                .foregroundStyle(message.isOutgoing ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.tint))
                .padding(.horizontal, isMediaOnly ? 8 : 0)
            }
            if let reply = message.replyTo {
                ReplyPreview(info: reply, isOutgoing: message.isOutgoing, model: model)
                    .padding(.horizontal, isMediaOnly ? 6 : 0)
            }
            MessageContentView(message: message, isOutgoing: message.isOutgoing, onMedia: onMedia)
            if !message.reactions.isEmpty {
                ReactionsView(reactions: message.reactions, isOutgoing: message.isOutgoing)
                    .padding(.horizontal, isMediaOnly ? 6 : 0)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            MessageFooter(message: message, isRead: isRead, onMedia: isMediaOnly || isBare)
                .padding(.trailing, isMediaOnly || isBare ? 6 : 0)
                .padding(.bottom, isMediaOnly || isBare ? 6 : 0)
        }
        .padding(isMediaOnly || isBare ? 0 : 8)
        .padding(.bottom, isMediaOnly || isBare ? 0 : 10)
        .background {
            if !isBare {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(message.isOutgoing ? appearance.outgoingStyle(localPremium: ayu.localPremium) : AnyShapeStyle(Theme.incomingBubble))
            }
        }
        .overlay {
            if message.ayuDeleted && !isBare {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: isBare ? 0 : 17, style: .continuous))
        .foregroundStyle(message.isOutgoing && !isBare ? Color.white : Color.primary)
        .opacity(message.ayuDeleted ? 0.85 : 1)
        .frame(maxWidth: 320, alignment: message.isOutgoing ? .trailing : .leading)
    }
}

/// Time, edited/deleted marks (AyuConfig.getEditedMark / getDeletedMark), views and read checks.
struct MessageFooter: View {
    let message: MessageItem
    let isRead: Bool
    var onMedia: Bool = false

    @Environment(AyuConfig.self) private var ayu

    private var markText: String? {
        let edited = message.isEdited
        let deleted = message.ayuDeleted
        switch (edited, deleted) {
        case (true, false): return ayu.editedMarkText
        case (false, true): return ayu.deletedMarkText
        case (true, true): return "\(ayu.editedMarkText) (\(ayu.deletedMarkText))"
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if message.viewCount > 0 && message.isChannelPost {
                Image(systemName: "eye.fill").font(.system(size: 9))
                Text(Formatters.compactCount(message.viewCount))
            }
            if !message.authorSignature.isEmpty {
                Text(message.authorSignature).lineLimit(1)
            }
            if let markText { Text(markText) }
            Text(Formatters.messageTime(message.date))
            if message.isOutgoing && !message.ayuDeleted {
                switch message.sendingState {
                case .pending: Image(systemName: "clock").font(.system(size: 10))
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                case .sent: Image(systemName: isRead ? "checkmark.circle.fill" : "checkmark").font(.system(size: 10, weight: .bold))
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(onMedia ? AnyShapeStyle(.white) : (message.isOutgoing ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)))
        .padding(.horizontal, onMedia ? 6 : 0)
        .padding(.vertical, onMedia ? 2 : 0)
        .background { if onMedia { Capsule().fill(Color.black.opacity(0.4)) } }
        .offset(y: onMedia ? 0 : 6)
    }
}

struct ReplyPreview: View {
    let info: ReplyInfo
    let isOutgoing: Bool
    let model: ChatViewModel

    @Environment(TelegramService.self) private var service
    @State private var loaded: MessageItem?

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(loaded.map { service.nameOf($0.sender) } ?? L("Message"))
                    .font(.caption.weight(.semibold))
                Text(info.quote ?? loaded.map { MessagePreview.text(for: $0.body) } ?? "…")
                    .font(.caption)
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isOutgoing ? Color.white : Color.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
        .task(id: info.messageId) {
            loaded = await model.loadReplied(info)
        }
    }
}

struct ReactionsView: View {
    let reactions: [ReactionItem]
    let isOutgoing: Bool

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(reactions.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 3) {
                    Text(r.emoji ?? "⭐️")
                    Text("\(r.count)").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(r.isChosen
                                           ? (isOutgoing ? Color.white.opacity(0.35) : Color.accentColor.opacity(0.35))
                                           : (isOutgoing ? Color.white.opacity(0.18) : Color.secondary.opacity(0.15))))
            }
        }
    }
}

/// Wrapping horizontal layout for reactions.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Grouped media (GroupedMessages on Android).
struct AlbumRow: View {
    let messages: [MessageItem]
    let chat: ChatItem?
    let isRead: Bool
    let onMedia: (MediaViewerItem) -> Void

    @Environment(AppearanceSettings.self) private var appearance
    @Environment(AyuConfig.self) private var ayu

    private var isOutgoing: Bool { messages.first?.isOutgoing ?? false }

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(messages) { m in
                        AlbumCell(message: m, onMedia: onMedia)
                    }
                }
                if let caption = messages.compactMap({ $0.body.richText }).first {
                    Text(RichTextRenderer.attributed(caption, linkColor: isOutgoing ? .white : .accentColor, fontSize: appearance.messageTextSize))
                        .font(.system(size: appearance.messageTextSize))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 14)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let last = messages.last {
                    MessageFooter(message: last, isRead: isRead, onMedia: true).padding(6)
                }
            }
            .background(isOutgoing ? appearance.outgoingStyle(localPremium: ayu.localPremium) : AnyShapeStyle(Theme.incomingBubble))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .foregroundStyle(isOutgoing ? Color.white : Color.primary)
            .overlay {
                if messages.contains(where: \.ayuDeleted) {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
            .frame(maxWidth: 320)
            if !isOutgoing { Spacer(minLength: 48) }
        }
    }
}

private struct AlbumCell: View {
    let message: MessageItem
    let onMedia: (MediaViewerItem) -> Void

    var body: some View {
        Group {
            switch message.body {
            case .photo(let p, _):
                MediaImage(file: p.file, thumb: p.thumb)
                    .onTapGesture { onMedia(.photo(p)) }
            case .video(let v, _):
                MediaImage(file: v.thumb?.file, thumb: v.thumb)
                    .overlay { PlayBadge() }
                    .overlay(alignment: .topLeading) { DurationLabel(seconds: v.duration).padding(6) }
                    .onTapGesture { onMedia(.video(v)) }
            default:
                MessageContentView(message: message, isOutgoing: message.isOutgoing, onMedia: onMedia)
            }
        }
        .frame(height: 150)
        .clipped()
    }
}

struct PlayBadge: View {
    var systemImage: String = "play.fill"

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.45)).frame(width: 44, height: 44)
            Image(systemName: systemImage).foregroundStyle(.white)
        }
    }
}

struct DurationLabel: View {
    let seconds: Int

    var body: some View {
        Text(Formatters.duration(seconds))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.45)))
    }
}
