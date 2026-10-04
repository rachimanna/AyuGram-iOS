import Foundation
import Observation

/// DialogsActivity data: folder tabs, archive, search and AyuGram preview blurring.
@MainActor
@Observable
final class ChatListViewModel {
    var selectedList: ChatListKey = .main
    var searchQuery: String = "" {
        didSet { scheduleSearch() }
    }
    private(set) var searchResults: [Int64] = []
    private(set) var isSearching = false

    @ObservationIgnored private let service = TelegramService.shared
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var chatIds: [Int64] { service.sortedChatIds(in: selectedList) }

    var archiveIds: [Int64] { service.sortedChatIds(in: .archive) }

    var tabs: [FolderTab] {
        [FolderTab(key: .main, title: L("FilterAllChats"))] + service.folders.map { FolderTab(key: .folder($0.id), title: $0.title) }
    }

    func onAppear() async {
        await service.loadChats(selectedList)
    }

    func select(_ list: ChatListKey) {
        selectedList = list
        Task { await service.loadChats(list) }
    }

    func loadMoreIfNeeded(currentId: Int64) {
        let ids = chatIds
        guard let idx = ids.firstIndex(of: currentId), idx >= ids.count - 10 else { return }
        Task { await service.loadChats(selectedList) }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let ids = await self.service.searchChats(q)
            guard !Task.isCancelled else { return }
            self.searchResults = ids
            self.isSearching = false
        }
    }

    /// Text for the second line of a chat cell, with AyuGram filter blur (DialogCell hook) and draft.
    func preview(for chat: ChatItem) -> (prefix: String?, text: String, isFiltered: Bool, isDraft: Bool) {
        if let draft = chat.draftText {
            return (L("Draft"), draft, false, true)
        }
        guard let last = chat.lastMessage else { return (nil, "", false, false) }
        var text = MessagePreview.text(for: last.body)
        if service.chatActions[chat.id] != nil {
            return (nil, service.chatActions[chat.id] ?? "", false, false)
        }
        var prefix: String?
        if last.isOutgoing && !last.body.isService {
            prefix = L("FromYou")
        } else if chat.kind.isGroup && !last.body.isService {
            prefix = service.nameOf(last.sender)
        }
        let filtered = AyuFilter.shared.isFiltered(text: last.body.plainText, dialogId: chat.id, messageId: last.id)
        if filtered { text = String(repeating: "▒", count: min(max(text.count, 6), 24)) }
        return (prefix, text, filtered, false)
    }
}

struct FolderTab: Identifiable, Hashable {
    var key: ChatListKey
    var title: String
    var id: ChatListKey { key }
}
