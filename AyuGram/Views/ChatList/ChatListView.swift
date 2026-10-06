import SwiftUI
import UIKit

/// DialogsActivity: folder tabs, archive, search, swipe actions and the AyuGram ghost toggle
/// (Android: navigation drawer item "Ghost Mode" / "Kill app").
struct ChatListView: View {
    @Environment(TelegramService.self) private var service
    @Environment(AppRouter.self) private var router
    @Environment(AyuConfig.self) private var ayu
    @State private var model = ChatListViewModel()
    @State private var showKillConfirm = false
    @State private var deleteCandidate: ChatItem?
    @State private var showVaultUnlock = false

    var body: some View {
        @Bindable var router = router
        @Bindable var model = model
        NavigationStack(path: $router.chatPath) {
            List {
                if model.searchQuery.isEmpty {
                    NavigationLink(L("DeletedFolder")) { UnifiedHistoryView() }
                    if model.tabs.count > 1 {
                        FolderTabs(tabs: model.tabs, selected: model.selectedList) { model.select($0) }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    if model.selectedList == .main, !model.archiveIds.isEmpty {
                        NavigationLink(value: Route.archive) {
                            ArchiveRow(count: model.archiveIds.count)
                        }
                    }
                    ForEach(model.chatIds, id: \.self) { id in
                        if let chat = service.chats[id] {
                            row(chat, list: model.selectedList)
                                .onAppear { model.loadMoreIfNeeded(currentId: id) }
                        }
                    }
                    if !service.isChatListFullyLoaded(model.selectedList) {
                        ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                            .task { await service.loadChats(model.selectedList) }
                    }
                } else {
                    if model.isSearching { ProgressView().frame(maxWidth: .infinity) }
                    ForEach(model.searchResults, id: \.self) { id in
                        if let chat = service.chats[id] {
                            NavigationLink(value: Route.chat(id)) { ChatRowView(chat: chat, preview: model.preview(for: chat)) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $model.searchQuery, prompt: L("Search"))
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .withAppRoutes()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if ayu.showGhostToggleInDrawer {
                        Button {
                            ayu.toggleGhostMode()
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } label: {
                            GhostGlyph(active: ayu.isGhostModeActive).frame(width: 24, height: 24)
                        }
                        .accessibilityLabel(L("GhostModeToggle"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if AppLock.shared.hasVaultPIN {
                        Button {
                            if AppLock.shared.vaultUnlocked { AppLock.shared.accountChanged() }
                            else { showVaultUnlock = true }
                        } label: { Image(systemName: AppLock.shared.vaultUnlocked ? "lock.open" : "lock.rectangle.stack") }
                        .accessibilityLabel(L("UnlockHiddenChats"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if ayu.showKillButtonInDrawer {
                        Button(role: .destructive) { showKillConfirm = true } label: {
                            Image(systemName: "power")
                        }
                        .accessibilityLabel(L("KillApp"))
                    }
                }
            }
            .task { await model.onAppear() }
            .sheet(isPresented: $showVaultUnlock) { PINUnlockView(vault: true) { showVaultUnlock = false } }
            .confirmationDialog(L("KillAppConfirm"), isPresented: $showKillConfirm, titleVisibility: .visible) {
                Button(L("KillApp"), role: .destructive) { AppKiller.kill() }
            }
            .confirmationDialog(L("DeleteChatConfirm"), isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
                                titleVisibility: .visible, presenting: deleteCandidate) { chat in
                Button(chat.kind.privateUserId != nil ? L("DeleteChat") : L("LeaveChat"), role: .destructive) {
                    Task { try? await service.leave(chatId: chat.id) }
                }
            }
        }
    }

    private var navigationTitle: String {
        switch service.connection {
        case .waitingForNetwork: return L("WaitingForNetwork")
        case .connecting, .connectingToProxy: return L("Connecting")
        case .updating: return L("Updating")
        case .ready: return ayu.isGhostModeActive ? L("GhostModeTitle") : L("Chats")
        }
    }

    @ViewBuilder
    private func row(_ chat: ChatItem, list: ChatListKey) -> some View {
        let pinned = chat.positions[list]?.isPinned ?? false
        let unread = chat.visibleUnreadCount(localReadUntil: LocalReadStore.shared.readUntil(chatId: chat.id)) > 0 || chat.isMarkedAsUnread
        NavigationLink(value: Route.chat(chat.id)) {
            ChatRowView(chat: chat, preview: model.preview(for: chat), isPinned: pinned)
        }
        .listRowBackground(pinned ? Color.secondary.opacity(0.07) : Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                let enabled = PrivacyPreferences.shared.isGhost(chat.id)
                PrivacyPreferences.shared.update(chat.id) { $0.ghost = enabled ? .off : .on }
            } label: { Label(L("GhostModeTitle"), systemImage: PrivacyPreferences.shared.isGhost(chat.id) ? "eye" : "eye.slash") }
            .tint(.purple)
            Button {
                Task { await service.markChatUnread(chatId: chat.id, unread: !unread) }
            } label: {
                Label(unread ? L("MarkAsRead") : L("MarkAsUnread"), systemImage: unread ? "envelope.open" : "envelope.badge")
            }
            .tint(.blue)
            Button {
                Task { await service.setPinned(chatId: chat.id, list: list, pinned: !pinned) }
            } label: {
                Label(pinned ? L("Unpin") : L("Pin"), systemImage: pinned ? "pin.slash" : "pin")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if AppLock.shared.hasVaultPIN {
                Button { PrivacyPreferences.shared.update(chat.id) { $0.hidden.toggle() } } label: { Label(L("HideChatBehindPIN"), systemImage: "lock") }.tint(.indigo)
            }
            Button(role: .destructive) { deleteCandidate = chat } label: { Label(L("Delete"), systemImage: "trash") }
            Button {
                Task { await service.setMuted(chatId: chat.id, muted: !chat.isMuted) }
            } label: {
                Label(chat.isMuted ? L("Unmute") : L("Mute"), systemImage: chat.isMuted ? "bell" : "bell.slash")
            }
            .tint(.orange)
            if list != .archive {
                Button {
                    Task { await service.setArchived(chatId: chat.id, archived: true) }
                } label: { Label(L("Archive"), systemImage: "archivebox") }
                .tint(.gray)
            }
        }
    }
}

struct FolderTabs: View {
    let tabs: [FolderTab]
    let selected: ChatListKey
    let onSelect: (ChatListKey) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    Button { onSelect(tab.key) } label: {
                        Text(tab.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selected == tab.key ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
                            .foregroundStyle(selected == tab.key ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct ArchiveRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.gray.opacity(0.6))
                Image(systemName: "archivebox.fill").foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading) {
                Text(L("ArchivedChats")).font(.headline)
                Text(LF("ChatsCount", count)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct ArchiveView: View {
    @Environment(TelegramService.self) private var service
    @State private var model = ChatListViewModel()

    var body: some View {
        List(model.chatIds, id: \.self) { id in
            if let chat = service.chats[id] {
                NavigationLink(value: Route.chat(id)) { ChatRowView(chat: chat, preview: model.preview(for: chat)) }
                    .swipeActions {
                        Button {
                            Task { await service.setArchived(chatId: id, archived: false) }
                        } label: { Label(L("Unarchive"), systemImage: "tray.and.arrow.up") }
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle(L("ArchivedChats"))
        .task {
            model.select(.archive)
        }
    }
}

/// "Kill app" drawer button (AyuConstants.DRAWER_KILL_APP). iOS has no API for an app to terminate
/// itself, so like Android's Process.killProcess this simply ends the process.
@MainActor
enum AppKiller {
    static func kill() {
        TelegramService.shared.setAppActive(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}
