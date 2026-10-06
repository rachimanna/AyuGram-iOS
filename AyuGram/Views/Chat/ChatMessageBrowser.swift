import SwiftUI

struct ChatMessageBrowser: View {
    let chatId: Int64
    var scheduled = false
    let onSelect: (MessageItem) -> Void
    @Environment(TelegramService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter: ChatSearchFilter = .all
    @State private var messages: [MessageItem] = []
    @State private var nextId: Int64 = 0
    @State private var secretOffset = ""
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var requestId = UUID()
    @State private var deleting: MessageItem?

    private var searchKey: String { query + "|" + filter.rawValue }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !scheduled {
                    Picker(L("Search"), selection: $filter) {
                        ForEach(ChatSearchFilter.allCases) { Text(L($0.rawValue)).tag($0) }
                    }.pickerStyle(.menu).padding(.horizontal)
                }
                List {
                    if let error { Text(error).foregroundStyle(.red) }
                    if !loading && messages.isEmpty && error == nil { Text(L("NoMessagesFound")).foregroundStyle(.secondary) }
                    ForEach(messages) { message in
                        Button { onSelect(message); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(service.nameOf(message.sender)).font(.subheadline.bold())
                                    Spacer()
                                    Text(Formatters.date(message.date), style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(MessagePreview.text(for: message.body)).font(.subheadline).lineLimit(3)
                                if scheduled { Text(Formatters.date(message.date), style: .time).font(.caption).foregroundStyle(.tint) }
                            }.foregroundStyle(.primary)
                        }
                        .contextMenu {
                            if scheduled {
                                Button(L("SendNow")) { Task { await sendNow(message) } }
                                Button(L("Delete"), role: .destructive) { deleting = message }
                            }
                        }
                    }
                    if loading { ProgressView() }
                    if hasMore && !loading { Button(L("LoadMore")) { Task { await load(reset: false) } } }
                }
                .refreshable { await load(reset: true) }
            }
            .navigationTitle(L(scheduled ? "ScheduledMessages" : "SearchInChat"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .searchable(text: $query, prompt: L("SearchInChat"))
            .task(id: searchKey) {
                if !scheduled { do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return } }
                await load(reset: true)
            }
            .confirmationDialog(L("DeleteMessageConfirm"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { message in
                Button(L("Delete"), role: .destructive) {
                    Task {
                        do { try await service.delete(chatId: chatId, messageIds: [message.id], revoke: true); await load(reset: true) }
                        catch { self.error = TelegramService.describe(error) }
                    }
                }
            }
        }
        .onDisappear { requestId = UUID() }
    }

    private func load(reset: Bool) async {
        if !reset && loading { return }
        guard let chat = service.chats[chatId], AppLock.shared.visible(chat), AppLock.shared.canShowContent else { return }
        let token = UUID()
        requestId = token
        let currentQuery = query, currentFilter = filter
        loading = true
        error = nil
        if reset { messages = []; nextId = 0; secretOffset = ""; hasMore = false }
        defer { if requestId == token { loading = false } }
        do {
            let page: MessageSearchPage
            if scheduled { page = MessageSearchPage(messages: try await service.scheduledMessages(chatId: chatId)) }
            else { page = try await service.searchMessages(chatId: chatId, query: currentQuery, filter: currentFilter, from: nextId, secretOffset: secretOffset) }
            guard requestId == token, !Task.isCancelled, AppLock.shared.canShowContent else { return }
            let visible = page.messages.filter {
                !AyuFilter.shared.appliesIn(isChannel: chat.kind.isChannel)
                || !AyuFilter.shared.isFiltered(text: $0.body.plainText, dialogId: chatId, messageId: $0.id)
            }
            let existing = Set(messages.map(\.id))
            messages += visible.filter { !existing.contains($0.id) }
            nextId = page.nextMessageId
            secretOffset = page.nextSecretOffset
            hasMore = page.hasMore
        } catch {
            if requestId == token, !Task.isCancelled { self.error = TelegramService.describe(error) }
        }
    }

    private func sendNow(_ message: MessageItem) async {
        do { try await service.sendScheduledNow(chatId: chatId, messageId: message.id); await load(reset: true) }
        catch { self.error = TelegramService.describe(error) }
    }
}
