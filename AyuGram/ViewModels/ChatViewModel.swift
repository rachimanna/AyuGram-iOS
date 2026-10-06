/*
 * iOS counterpart of Telegram Android's ChatActivity data handling, including AyuGram hooks:
 *   • deleted messages stay visible with the 🧹 mark and are merged back in from the AyuGram DB
 *   • "Edits history" availability (EditedMessageDao.hasAnyRevisions)
 *   • regex filters hide messages (ChatActivity getItemViewType hook)
 *   • ghost mode: read packets are not sent, "Read until here" sends one explicitly
 */

import Foundation
import Observation
import UIKit

enum ChatRow: Identifiable, Hashable {
    case day(Int)                 // unix date of the day start
    case message(MessageItem)
    case album([MessageItem])
    case sponsored(title: String, text: String, url: String)

    var id: String {
        switch self {
        case .day(let d): return "day\(d)"
        case .message(let m): return "m\(m.id)"
        case .album(let ms): return "a\(ms.first?.mediaAlbumId ?? 0)_\(ms.first?.id ?? 0)"
        case .sponsored: return "sponsored"
        }
    }
}

enum ComposerMode: Equatable {
    case normal
    case reply(MessageItem)
    case edit(MessageItem)
}

@MainActor
@Observable
final class ChatViewModel: ChatEventSink {
    let chatId: Int64
    private(set) var messages: [MessageItem] = []          // ascending by id
    private(set) var rows: [ChatRow] = []                  // newest first (the list is rendered inverted)
    private(set) var isLoadingOlder = false
    private(set) var reachedOldest = false
    private(set) var errorText: String?
    var composerText: String = "" { didSet { onComposerChanged(oldValue) } }
    var mode: ComposerMode = .normal
    private(set) var isSending = false
    var hiddenByFilterCount = 0

    @ObservationIgnored private let service = TelegramService.shared
    @ObservationIgnored private let config = AyuConfig.shared
    @ObservationIgnored private var revisionIds: Set<Int64> = []
    @ObservationIgnored private var pendingViews: Set<Int64> = []
    @ObservationIgnored private var viewFlushTask: Task<Void, Never>?
    @ObservationIgnored private var lastTypingSent = Date.distantPast
    @ObservationIgnored private var sponsored: (title: String, text: String, url: String)?
    @ObservationIgnored private var didOpen = false

    init(chatId: Int64) {
        self.chatId = chatId
        composerText = service.chats[chatId]?.draftText ?? ""
    }

    var chat: ChatItem? { service.chats[chatId] }

    var isChannel: Bool { chat?.kind.isChannel ?? false }

    var canWrite: Bool {
        guard let chat else { return false }
        switch chat.kind {
        case .channel(let id), .supergroup(let id):
            return service.supergroups[id]?.canPost ?? !chat.kind.isChannel
        case .user(let uid), .bot(let uid):
            return service.users[uid]?.isDeleted != true
        default:
            return true
        }
    }

    var canSendPoll: Bool {
        switch chat?.kind {
        case .basicGroup, .supergroup, .channel, .bot, .savedMessages: return canWrite
        default: return false
        }
    }

    var canSchedule: Bool {
        if case .secret = chat?.kind { return false }
        return canWrite
    }

    func reportError(_ error: Swift.Error) { errorText = TelegramService.describe(error) }

    // MARK: - Lifecycle

    func onAppear() async {
        service.subscribe(chatId: chatId, self)
        guard !didOpen else { return }
        didOpen = true
        await service.openChat(chatId)
        await loadInitial()
        if isChannel { sponsored = await service.sponsoredMessage(chatId: chatId); rebuildRows() }
    }

    func onDisappear() async {
        service.unsubscribe(chatId: chatId, self)
        viewFlushTask?.cancel()
        pendingViews = []
        await service.saveDraft(chatId: chatId, text: composerText)
        await service.closeChat(chatId)
        didOpen = false
    }

    // MARK: - Loading

    private func loadInitial() async {
        var collected: [MessageItem] = []
        var from: Int64 = 0
        // TDLib first returns what it has locally; repeat until we have a screenful.
        for _ in 0..<4 {
            guard let page = try? await service.history(chatId: chatId, from: from, limit: 50), !page.isEmpty else { break }
            collected += page
            from = page.map(\.id).min() ?? from
            if collected.count >= 30 { break }
        }
        merge(collected)
        await mergeAyuData(range: (collected.map(\.id).min() ?? 0, Int64.max))
        if collected.isEmpty { reachedOldest = true }
    }

    func loadOlder() async {
        guard !isLoadingOlder, !reachedOldest, let oldest = messages.first(where: { !$0.ayuDeleted })?.id ?? messages.first?.id else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await service.history(chatId: chatId, from: oldest, limit: 50)
            let older = page.filter { $0.id < oldest }
            if older.isEmpty {
                reachedOldest = true
                // Saved deleted messages older than anything Telegram still has.
                await mergeAyuData(range: (0, oldest))
                return
            }
            merge(older)
            await mergeAyuData(range: (older.map(\.id).min() ?? 0, oldest))
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Merges AyuGram-saved deleted messages and the "has revisions" flags for a loaded id range.
    private func mergeAyuData(range: (Int64, Int64)) async {
        let deleted: [MessageItem] = await withCheckedContinuation { cont in
            AyuMessagesController.shared.deletedMessages(chatId: chatId, startId: range.0, endId: range.1, limit: 500) { cont.resume(returning: $0) }
        }
        if !deleted.isEmpty { merge(deleted) }
        let ids = messages.filter { $0.id >= range.0 && $0.id <= range.1 }.map(\.id)
        let withRevisions: Set<Int64> = await withCheckedContinuation { cont in
            AyuMessagesController.shared.messagesWithRevisions(chatId: chatId, messageIds: ids) { cont.resume(returning: $0) }
        }
        revisionIds.formUnion(withRevisions)
        applyRevisionFlags()
    }

    private func merge(_ incoming: [MessageItem]) {
        guard !incoming.isEmpty else { return }
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in incoming {
            if let existing = byId[m.id], !existing.ayuDeleted, m.ayuDeleted {
                continue // live message wins over an older saved copy
            }
            byId[m.id] = m
        }
        messages = byId.values.sorted { $0.id < $1.id }
        applyRevisionFlags()
    }

    private func applyRevisionFlags() {
        var changed = false
        for i in messages.indices {
            let has = revisionIds.contains(messages[i].id)
            if messages[i].ayuHasRevisions != has {
                messages[i].ayuHasRevisions = has
                changed = true
            }
        }
        _ = changed
        rebuildRows()
    }

    // MARK: - Rows (day separators, albums, filters)

    private func rebuildRows() {
        let filter = AyuFilter.shared
        let filtersApply = filter.appliesIn(isChannel: isChannel)
        var hidden = 0
        var result: [ChatRow] = []
        var lastDay: Int?
        var i = 0
        let calendar = Calendar.current
        while i < messages.count {
            let m = messages[i]
            var group = [m]
            if m.mediaAlbumId != 0 {
                var j = i + 1
                while j < messages.count, messages[j].mediaAlbumId == m.mediaAlbumId { group.append(messages[j]); j += 1 }
            }
            i += group.count

            if filtersApply {
                let text = group.map(\.body.plainText).first { !$0.isEmpty }
                if filter.isFiltered(text: text, dialogId: chatId, messageId: m.id, groupMessageIds: group.map(\.id)) {
                    hidden += group.count
                    continue
                }
            }

            let dayStart = Int(calendar.startOfDay(for: Formatters.date(m.date)).timeIntervalSince1970)
            if dayStart != lastDay {
                result.append(.day(dayStart))
                lastDay = dayStart
            }
            result.append(group.count > 1 ? .album(group) : .message(m))
        }
        if let sponsored { result.append(.sponsored(title: sponsored.title, text: sponsored.text, url: sponsored.url)) }
        rows = result.reversed()
        hiddenByFilterCount = hidden
    }

    // MARK: - ChatEventSink

    func handle(_ event: ChatEvent) {
        switch event {
        case .newMessage(let m):
            guard !m.isScheduled else { return }
            merge([m])
        case .sendSucceeded(let oldId, let m):
            messages.removeAll { $0.id == oldId }
            merge([m])
        case .sendFailed(let oldId, let m):
            messages.removeAll { $0.id == oldId }
            merge([m])
        case .replyMarkupChanged(let id, let rows):
            update(id) { $0.inlineKeyboard = rows }
        case .pollChanged(let id, let poll):
            for index in messages.indices {
                if case .poll(let current) = messages[index].body, current.pollId == id {
                    messages[index].body = .poll(poll)
                }
            }
            rebuildRows()
        case .contentChanged(let id, let body):
            update(id) { $0.body = body }
        case .edited(let id, let editDate):
            update(id) { $0.editDate = editDate }
        case .deleted(let ids, let saved):
            let savedIds = Set(saved.map(\.id))
            messages.removeAll { ids.contains($0.id) && !savedIds.contains($0.id) && !$0.ayuDeleted }
            for s in saved {
                if let idx = messages.firstIndex(where: { $0.id == s.id }) {
                    var copy = messages[idx]
                    copy.ayuDeleted = true
                    messages[idx] = copy
                } else {
                    merge([s])
                }
            }
            rebuildRows()
        case .interaction(let id, let reactions, let views, let replies):
            update(id) { $0.reactions = reactions; $0.viewCount = views; $0.replyCount = replies }
        case .pinned(let id, let isPinned):
            update(id) { $0.isPinned = isPinned }
        case .readOutbox:
            rebuildRows()
        case .revisionsAdded(let id):
            revisionIds.insert(id)
            applyRevisionFlags()
        }
    }

    private func update(_ id: Int64, _ change: (inout MessageItem) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[idx])
        rebuildRows()
    }

    // MARK: - Viewing (read packets)

    func messageAppeared(_ m: MessageItem) {
        service.setMessageDisplayed(chatId: chatId, messageId: m.id, displayed: true)
        service.preserveViewed(m)
        guard !m.isOutgoing, !m.ayuDeleted, m.id > 0 else { return }
        pendingViews.insert(m.id)
        viewFlushTask?.cancel()
        viewFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flushViews()
        }
    }

    func messageDisappeared(_ m: MessageItem) {
        service.setMessageDisplayed(chatId: chatId, messageId: m.id, displayed: false)
    }

    private func flushViews() {
        guard !pendingViews.isEmpty else { return }
        let ids = Array(pendingViews)
        pendingViews = []
        service.markViewed(chatId: chatId, messageIds: ids)
    }

    /// AyuGram "Read until here" (OPTION_READ_UNTIL).
    func readUntil(_ m: MessageItem) async {
        await service.markReadOnServer(chatId: chatId, untilMessageId: m.id)
    }

    func isRead(_ m: MessageItem) -> Bool {
        m.isOutgoing && (chat?.lastReadOutboxMessageId ?? 0) >= m.id
    }

    func reveal(_ message: MessageItem) async {
        guard !message.isScheduled else { return }
        do {
            let around = try await service.history(chatId: chatId, from: message.id, offset: -15, limit: 40)
            merge(around + [message])
        } catch { errorText = TelegramService.describe(error) }
    }

    func rowID(for messageId: Int64) -> String {
        for row in rows {
            switch row {
            case .message(let m) where m.id == messageId: return row.id
            case .album(let items) where items.contains(where: { $0.id == messageId }): return row.id
            default: continue
            }
        }
        return "m\(messageId)"
    }

    // MARK: - Composer

    private func onComposerChanged(_ old: String) {
        guard composerText != old, !composerText.isEmpty, Date().timeIntervalSince(lastTypingSent) > 5 else { return }
        lastTypingSent = Date()
        service.sendTyping(chatId: chatId) // no-op with "Don't send typing"
    }

    func startReply(_ m: MessageItem) { mode = .reply(m) }

    func startEdit(_ m: MessageItem) {
        mode = .edit(m)
        composerText = m.body.plainText
    }

    func cancelComposerMode() {
        if case .edit = mode { composerText = "" }
        mode = .normal
    }

    /// Every rejected send reports its reason without touching the user's draft or reply.
    private func canBeginSending() -> Bool {
        guard !isSending else { return false }
        guard service.authStep == .ready else {
            errorText = TelegramService.describe(TelegramServiceError.notReady)
            return false
        }
        guard canWrite else {
            errorText = L("CannotWriteToChat")
            return false
        }
        return true
    }

    func send(delivery: MessageDelivery = MessageDelivery()) async {
        guard canBeginSending() else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if case .edit(let message) = mode, case .text = message.body { return }
            else if case .edit = mode {} else { return }
        }
        if let date = delivery.scheduledDate, date.timeIntervalSinceNow < 15 {
            errorText = L("ScheduleTooSoon"); return
        }
        let originalText = composerText
        let current = mode
        isSending = true
        defer { isSending = false }
        do {
            switch current {
            case .edit(let m):
                let original = m.body.richText
                let rich = original?.text == text ? original! : RichText(text: text)
                if case .text = m.body {
                    try await service.editText(chatId: chatId, messageId: m.id, text: rich)
                } else {
                    try await service.editCaption(chatId: chatId, messageId: m.id, text: rich)
                }
            case .reply(let m):
                try await service.sendText(chatId: chatId, text: RichText(text: text), replyToMessageId: m.id, delivery: delivery)
            case .normal:
                try await service.sendText(chatId: chatId, text: RichText(text: text), replyToMessageId: nil, delivery: delivery)
            }
            // Only clear the submitted draft, never a draft changed during the request.
            if composerText == originalText && mode == current {
                composerText = ""
                mode = .normal
            }
            if case .edit = current {} else if delivery.scheduledDate != nil { infoText = L("SentAsScheduled") } else { notifyIfScheduled() }
        } catch {
            errorText = TelegramService.describe(error)
        }
    }

    func sendPhoto(data: Data) async {
        guard canBeginSending() else { return }
        isSending = true
        defer { isSending = false }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
            errorText = L("ErrorOccurred")
            return
        }
        let url = Self.outgoingDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        let current = mode
        do {
            try jpeg.write(to: url)
            let replyId: Int64? = { if case .reply(let m) = mode { return m.id }; return nil }()
            try await service.sendPhoto(chatId: chatId, path: url.path, width: Int(image.size.width * image.scale),
                                        height: Int(image.size.height * image.scale), caption: "", replyToMessageId: replyId)
            if mode == current { mode = .normal }
            notifyIfScheduled()
        } catch {
            errorText = TelegramService.describe(error)
        }
    }

    func sendFile(url source: URL) async {
        guard canBeginSending() else { return }
        isSending = true
        defer { isSending = false }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let dir = Self.outgoingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = dir.appendingPathComponent(source.lastPathComponent)
        let current = mode
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
            let replyId: Int64? = { if case .reply(let m) = mode { return m.id }; return nil }()
            try await service.sendDocument(chatId: chatId, path: target.path, caption: "", replyToMessageId: replyId)
            if mode == current { mode = .normal }
            notifyIfScheduled()
        } catch {
            errorText = TelegramService.describe(error)
        }
    }

    private var replyId: Int64? {
        if case .reply(let message) = mode { return message.id }
        return nil
    }

    func sendBotText(_ text: String, keyboard: BotReplyKeyboard) async {
        guard canBeginSending() else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await service.sendText(chatId: chatId, text: RichText(text: text),
                replyToMessageId: keyboard.forceReply ? keyboard.messageId : replyId)
            if keyboard.oneTime { service.botKeyboards[chatId] = nil }
            notifyIfScheduled()
        } catch { errorText = TelegramService.describe(error) }
    }

    @discardableResult
    func sendVoice(url: URL, duration: Int) async -> Bool {
        guard canBeginSending() else { return false }
        let current = mode
        isSending = true
        defer { isSending = false }
        do {
            try await service.sendVoice(chatId: chatId, path: url.path, duration: duration, replyToMessageId: replyId)
            if mode == current { mode = .normal }
            notifyIfScheduled()
            return true
        } catch { errorText = TelegramService.describe(error); return false }
    }

    func sendVideo(url: URL) async {
        guard canBeginSending() else { return }
        let current = mode
        isSending = true
        defer { isSending = false; try? FileManager.default.removeItem(at: url) }
        do {
            let video = try await OutgoingVideo.prepare(url)
            do {
                try await service.sendVideo(chatId: chatId, path: video.url.path, width: video.width, height: video.height,
                                             duration: video.duration, replyToMessageId: replyId)
            } catch {
                try? FileManager.default.removeItem(at: video.url)
                throw error
            }
            if mode == current { mode = .normal }
            notifyIfScheduled()
        } catch { errorText = TelegramService.describe(error) }
    }

    @discardableResult
    func sendPoll(_ draft: PollDraft) async -> Bool {
        guard canBeginSending() else { return false }
        let current = mode
        isSending = true
        defer { isSending = false }
        do {
            try await service.sendPoll(chatId: chatId, draft: draft, replyToMessageId: replyId)
            if mode == current { mode = .normal }
            notifyIfScheduled()
            return true
        } catch { errorText = TelegramService.describe(error); return false }
    }

    @discardableResult
    func sendSticker(_ sticker: StickerItem) async -> Bool {
        guard canBeginSending() else { return false }
        let current = mode
        isSending = true
        defer { isSending = false }
        do {
            try await service.sendSticker(chatId: chatId, sticker: sticker, replyToMessageId: replyId)
            if mode == current { mode = .normal }
            notifyIfScheduled()
            return true
        } catch { errorText = TelegramService.describe(error); return false }
    }

    func react(_ message: MessageItem, emoji: String) async {
        do { try await service.toggleReaction(message, emoji: emoji) }
        catch { errorText = TelegramService.describe(error) }
    }

    func pin(_ message: MessageItem) async {
        do { try await service.pinMessage(message) }
        catch { errorText = TelegramService.describe(error) }
    }

    private func notifyIfScheduled() {
        if config.useScheduledMessages { infoText = L("SentAsScheduled") }
    }

    var infoText: String?

    func clearError() { errorText = nil; infoText = nil }

    nonisolated static var outgoingDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Message actions

    func delete(_ ids: [Int64], revoke: Bool) async {
        // Saved deleted messages (🧹) only exist locally: remove them from the AyuGram DB.
        let local = messages.filter { ids.contains($0.id) && $0.ayuDeleted }.map(\.id)
        for id in local { AyuMessagesController.shared.removeSavedDeleted(chatId: chatId, messageId: id) }
        messages.removeAll { local.contains($0.id) }
        rebuildRows()
        let remote = ids.filter { !local.contains($0) }
        guard !remote.isEmpty else { return }
        do {
            try await service.delete(chatId: chatId, messageIds: remote, revoke: revoke)
        } catch {
            errorText = TelegramService.describe(error)
        }
    }

    func forward(_ m: MessageItem, to target: Int64) async {
        do {
            try await service.forward(messageIds: [m.id], from: chatId, to: target)
        } catch {
            errorText = TelegramService.describe(error)
        }
    }

    func revisions(of m: MessageItem) async -> [EditRevision] {
        await withCheckedContinuation { cont in
            AyuMessagesController.shared.revisions(chatId: chatId, messageId: m.id) { cont.resume(returning: $0) }
        }
    }

    func canEdit(_ m: MessageItem) -> Bool {
        guard m.isOutgoing, !m.ayuDeleted, m.sendingState == .sent else { return false }
        switch m.body {
        case .text, .photo, .video, .document, .audio, .animation: break
        default: return false
        }
        // Telegram allows editing for 48 hours (unlimited in Saved Messages).
        if case .savedMessages = chat?.kind { return true }
        return Date().timeIntervalSince1970 - TimeInterval(m.date) < 48 * 3600
    }

    func message(_ id: Int64) -> MessageItem? {
        messages.first { $0.id == id }
    }

    /// Loads a replied-to message that is not in the loaded window.
    func loadReplied(_ info: ReplyInfo) async -> MessageItem? {
        if info.chatId == chatId, let m = message(info.messageId) { return m }
        return await service.message(chatId: info.chatId, id: info.messageId)
    }
}
