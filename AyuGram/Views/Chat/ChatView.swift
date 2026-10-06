import PhotosUI
import SwiftUI
import UIKit

/// ChatActivity: inverted message list, header, composer and the AyuGram message menu
/// (Edits history, Read until here, deleted-message actions).
struct ChatView: View {
    let chatId: Int64

    @Environment(TelegramService.self) private var service
    @Environment(AyuConfig.self) private var ayu
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(AppRouter.self) private var router
    @State private var model: ChatViewModel
    @State private var historyFor: MessageItem?
    @State private var forwardFor: MessageItem?
    @State private var deleteFor: MessageItem?
    @State private var detailsFor: MessageItem?
    @State private var mediaViewer: MediaViewerItem?

    init(chatId: Int64) {
        self.chatId = chatId
        _model = State(initialValue: ChatViewModel(chatId: chatId))
    }

    private var chat: ChatItem? { service.chats[chatId] }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if model.hiddenByFilterCount > 0 {
                Text(LF("FilteredMessagesHidden", model.hiddenByFilterCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ComposerBar(model: model)
        }
        .background { ChatBackdrop().ignoresSafeArea() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink(value: Route.profile(chatId: chatId)) { ChatHeader(chatId: chatId) }
                    .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink(value: Route.deletedMessages(chatId: chatId)) {
                        Label(L("DeletedMessages"), systemImage: "trash.slash")
                    }
                    if let last = chat?.lastMessage {
                        Button {
                            Task { await model.readUntil(last) }
                        } label: { Label(L("ReadAll"), systemImage: "checkmark.message") }
                    }
                    Button {
                        Task { await service.setMuted(chatId: chatId, muted: !(chat?.isMuted ?? false)) }
                    } label: {
                        Label(chat?.isMuted == true ? L("Unmute") : L("Mute"), systemImage: chat?.isMuted == true ? "bell" : "bell.slash")
                    }
                } label: {
                    AvatarView(id: chatId, title: chat?.title ?? "", photo: chat?.photo, size: 34, colorId: chat?.accentColorId,
                               isSavedMessages: chat?.isSavedMessages ?? false)
                }
            }
        }
        .task { await model.onAppear() }
        .onDisappear { Task { await model.onDisappear() } }
        .sheet(item: $historyFor) { m in EditsHistoryView(message: m, model: model) }
        .sheet(item: $forwardFor) { m in
            ChatPickerView(title: L("ForwardTo")) { target in
                Task { await model.forward(m, to: target) }
            }
        }
        .sheet(item: $detailsFor) { m in MessageDetailsView(message: m) }
        .fullScreenCover(item: $mediaViewer) { item in MediaViewer(item: item) }
        .confirmationDialog(L("DeleteMessageConfirm"), isPresented: Binding(get: { deleteFor != nil }, set: { if !$0 { deleteFor = nil } }),
                            titleVisibility: .visible, presenting: deleteFor) { m in
            if m.ayuDeleted {
                Button(L("DeleteFromAyuDatabase"), role: .destructive) { Task { await model.delete([m.id], revoke: false) } }
            } else {
                if (m.isOutgoing || chat?.canBeDeletedForAllUsers == true) && chat?.isSavedMessages != true {
                    Button(L("DeleteForEveryone"), role: .destructive) { Task { await model.delete([m.id], revoke: true) } }
                }
                Button(L("DeleteForMe"), role: .destructive) { Task { await model.delete([m.id], revoke: false) } }
            }
        }
        .alert(L("AppName"), isPresented: Binding(get: { model.errorText != nil || model.infoText != nil }, set: { if !$0 { model.clearError() } })) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.errorText ?? model.infoText ?? "")
        }
        .environment(\.openURL, OpenURLAction { url in handle(url) })
    }

    // MARK: - List

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.rows) { row in
                    rowView(row)
                        .scaleEffect(x: 1, y: -1)
                }
                if !model.reachedOldest {
                    ProgressView()
                        .padding()
                        .scaleEffect(x: 1, y: -1)
                        .task { await model.loadOlder() }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scaleEffect(x: 1, y: -1)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .day(let date):
            Text(Formatters.dayHeader(date))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.25), in: Capsule())
                .padding(.vertical, 6)
        case .message(let m):
            MessageRow(message: m, chat: chat, isRead: model.isRead(m), model: model, onMedia: { mediaViewer = $0 })
                .contextMenu { menu(for: m) }
                .onAppear { model.messageAppeared(m) }
                .id(m.id)
        case .album(let ms):
            AlbumRow(messages: ms, chat: chat, isRead: ms.last.map(model.isRead) ?? false, onMedia: { mediaViewer = $0 })
                .contextMenu { if let first = ms.first { menu(for: first) } }
                .onAppear { ms.forEach(model.messageAppeared) }
        case .sponsored(let title, let text, let url):
            SponsoredCard(title: title, text: text, url: url)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func menu(for m: MessageItem) -> some View {
        if !m.ayuDeleted && !m.body.isService {
            Button { model.startReply(m) } label: { Label(L("Reply"), systemImage: "arrowshape.turn.up.left") }
        }
        if !m.body.plainText.isEmpty {
            Button { UIPasteboard.general.string = m.body.plainText } label: { Label(L("Copy"), systemImage: "doc.on.doc") }
        }
        if model.canEdit(m), case .text = m.body {
            Button { model.startEdit(m) } label: { Label(L("Edit"), systemImage: "pencil") }
        }
        if !m.ayuDeleted && chat?.hasProtectedContent != true && !m.body.isService {
            Button { forwardFor = m } label: { Label(L("Forward"), systemImage: "arrowshape.turn.up.right") }
        }
        // --- AyuGram: OPTION_HISTORY
        if m.ayuHasRevisions {
            Button { historyFor = m } label: { Label(L("EditsHistoryMenu"), systemImage: "clock.arrow.circlepath") }
        }
        // --- AyuGram: OPTION_READ_UNTIL (only meaningful when read packets are suppressed)
        if !ayu.sendReadPackets && !m.isOutgoing && !m.ayuDeleted {
            Button { Task { await model.readUntil(m) } } label: { Label(L("ReadUntilMenuText"), systemImage: "eye") }
        }
        Button { detailsFor = m } label: { Label(L("Details"), systemImage: "info.circle") }
        Divider()
        Button(role: .destructive) { deleteFor = m } label: { Label(L("Delete"), systemImage: "trash") }
    }

    // MARK: - Links

    private func handle(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "ayugram" else {
            if let tg = TelegramLink.parse(url) {
                Task { if let id = await TelegramLink.resolve(tg) { router.chatPath.append(.chat(id)) } }
                return .handled
            }
            return .systemAction
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "user":
            if let s = parts.first, let uid = Int64(s) {
                Task { if let id = await service.privateChat(with: uid) { router.chatPath.append(.chat(id)) } }
            }
        case "resolve":
            if let name = parts.first {
                Task { if let id = await TelegramLink.resolve(.username(name)) { router.chatPath.append(.chat(id)) } }
            }
        case "command":
            if let cmd = parts.first?.removingPercentEncoding {
                model.composerText = cmd + " "
            }
        default:
            break
        }
        return .handled
    }
}

/// Title + subtitle (status, members, typing…) shown in the navigation bar.
struct ChatHeader: View {
    let chatId: Int64
    @Environment(TelegramService.self) private var service
    @Environment(AyuConfig.self) private var ayu

    var body: some View {
        let chat = service.chats[chatId]
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(service.chatTitle(chatId)).font(.headline).lineLimit(1)
                if ayu.isGhostModeActive { GhostGlyph().frame(width: 14, height: 14) }
            }
            Text(subtitle(chat))
                .font(.caption)
                .foregroundStyle(service.chatActions[chatId] != nil || isOnline(chat) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
    }

    private func isOnline(_ chat: ChatItem?) -> Bool {
        guard let uid = chat?.kind.privateUserId, case .online = service.users[uid]?.status else { return false }
        return true
    }

    private func subtitle(_ chat: ChatItem?) -> String {
        if let action = service.chatActions[chatId] { return action }
        guard let chat else { return "" }
        switch chat.kind {
        case .savedMessages: return ""
        case .user(let uid), .bot(let uid), .secret(let uid):
            return service.users[uid].map { Formatters.presence($0.status) } ?? ""
        case .basicGroup(let id):
            return Formatters.members(service.basicGroupMembers[id] ?? 0, channel: false)
        case .supergroup(let id):
            return Formatters.members(service.supergroups[id]?.memberCount ?? 0, channel: false)
        case .channel(let id):
            return Formatters.members(service.supergroups[id]?.memberCount ?? 0, channel: true)
        }
    }
}

struct SponsoredCard: View {
    let title: String
    let text: String
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("SponsoredMessage")).font(.caption.bold()).foregroundStyle(.tint)
            Text(title).font(.subheadline.bold())
            Text(text).font(.subheadline)
            if let link = URL(string: url) {
                Link(L("OpenLink"), destination: link).font(.subheadline.bold())
            }
        }
        .padding(10)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Theme.incomingBubble, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
