import SwiftUI
import UIKit

/// ProfileActivity for users, groups and channels.
struct ProfileView: View {
    let chatId: Int64

    @Environment(TelegramService.self) private var service
    @Environment(AppRouter.self) private var router
    @Environment(AyuConfig.self) private var ayu
    @State private var userInfo: UserProfileInfo?
    @State private var groupInfo: GroupInfo?
    @State private var confirmClear = false
    @State private var confirmLeave = false
    @State private var showAvatar = false

    private var chat: ChatItem? { service.chats[chatId] }
    private var user: UserItem? { chat?.kind.privateUserId.flatMap { service.users[$0] } }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AvatarView(id: chatId, title: chat?.title ?? "", photo: chat?.photo, size: 104, colorId: chat?.accentColorId,
                               isSavedMessages: chat?.isSavedMessages ?? false)
                        .onTapGesture { if chat?.photo?.big != nil { showAvatar = true } }
                    HStack(spacing: 6) {
                        Text(service.chatTitle(chatId)).font(.title2.bold()).multilineTextAlignment(.center)
                        if user?.isPremium == true || (user?.id == service.myUserId && ayu.localPremium) {
                            Image(systemName: "star.fill").foregroundStyle(.purple)
                        }
                        if user?.isVerified == true { Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint) }
                    }
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                if let user {
                    if !user.phoneNumber.isEmpty {
                        info(L("Phone"), "+" + user.phoneNumber, copy: "+" + user.phoneNumber)
                    }
                    if let username = user.username {
                        info(L("Username"), "@" + username, copy: "https://t.me/" + username)
                    }
                    if let bio = userInfo?.bio, !bio.isEmpty {
                        info(user.isBot ? L("BotAbout") : L("Bio"), bio, copy: bio)
                    }
                    info("ID", "\(user.id)", copy: "\(user.id)")
                } else if let groupInfo {
                    if !groupInfo.description.isEmpty {
                        info(L("Description"), groupInfo.description, copy: groupInfo.description)
                    }
                    if let username = groupInfo.username {
                        info(L("Link"), "t.me/" + username, copy: "https://t.me/" + username)
                    } else if let link = groupInfo.inviteLink {
                        info(L("InviteLink"), link, copy: link)
                    }
                    info("ID", "\(chatId)", copy: "\(chatId)")
                }
            }

            Section {
                Toggle(isOn: Binding(get: { !(chat?.isMuted ?? false) },
                                     set: { on in Task { await service.setMuted(chatId: chatId, muted: !on) } })) {
                    Label(L("Notifications"), systemImage: "bell")
                }
                NavigationLink(value: Route.deletedMessages(chatId: chatId)) {
                    Label(L("DeletedMessages"), systemImage: "trash.slash")
                }
                if let uid = user?.id, uid != service.myUserId, chat == nil {
                    Button(L("SendMessage")) {
                        Task { if let id = await service.privateChat(with: uid) { router.chatPath.append(.chat(id)) } }
                    }
                }
            }

            Section {
                Button(L("ClearHistory"), role: .destructive) { confirmClear = true }
                if !(chat?.isSavedMessages ?? false) {
                    Button(chat?.kind.privateUserId != nil ? L("DeleteChat") : (chat?.kind.isChannel == true ? L("LeaveChannel") : L("LeaveGroup")),
                           role: .destructive) { confirmLeave = true }
                }
            }
        }
        .navigationTitle(L("Info"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let uid = chat?.kind.privateUserId {
                await service.loadUser(uid)
                userInfo = await service.userFullInfo(uid)
            } else {
                groupInfo = await service.groupInfo(chatId: chatId)
            }
        }
        .confirmationDialog(L("ClearHistoryConfirm"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("ClearHistory"), role: .destructive) { Task { try? await service.clearHistory(chatId: chatId, revoke: false) } }
        }
        .confirmationDialog(L("DeleteChatConfirm"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) {
                Task {
                    try? await service.leave(chatId: chatId)
                    router.chatPath = []
                }
            }
        }
        .fullScreenCover(isPresented: $showAvatar) {
            if let big = chat?.photo?.big {
                MediaViewer(item: .photo(PhotoItem(thumb: nil, file: big, width: 640, height: 640)))
            }
        }
    }

    private var subtitle: String {
        guard let chat else { return "" }
        switch chat.kind {
        case .savedMessages: return ""
        case .user, .bot, .secret: return user.map { Formatters.presence($0.status) } ?? ""
        case .basicGroup(let id): return Formatters.members(groupInfo?.memberCount ?? service.basicGroupMembers[id] ?? 0, channel: false)
        case .supergroup(let id): return Formatters.members(groupInfo?.memberCount ?? service.supergroups[id]?.memberCount ?? 0, channel: false)
        case .channel(let id): return Formatters.members(groupInfo?.memberCount ?? service.supergroups[id]?.memberCount ?? 0, channel: true)
        }
    }

    private func info(_ title: String, _ value: String, copy: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).textSelection(.enabled)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button { UIPasteboard.general.string = copy } label: { Label(L("Copy"), systemImage: "doc.on.doc") }
        }
    }
}

/// Contacts tab.
struct ContactsView: View {
    @Environment(TelegramService.self) private var service
    @Environment(AppRouter.self) private var router
    @State private var contacts: [UserItem] = []
    @State private var query = ""

    private var filtered: [UserItem] {
        query.isEmpty ? contacts : contacts.filter { $0.fullName.localizedCaseInsensitiveContains(query) || ($0.username ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { user in
                Button {
                    Task {
                        if let id = await service.privateChat(with: user.id) { router.openChat(id) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(id: user.id, title: user.fullName, photo: user.photo, size: 44, colorId: user.accentColorId)
                        VStack(alignment: .leading) {
                            Text(user.fullName).foregroundStyle(.primary)
                            Text(Formatters.presence(user.status))
                                .font(.caption)
                                .foregroundStyle(isOnline(user) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query)
            .navigationTitle(L("Contacts"))
            .task { contacts = await service.contacts() }
            .refreshable { contacts = await service.contacts() }
        }
    }

    private func isOnline(_ u: UserItem) -> Bool {
        if case .online = service.users[u.id]?.status ?? u.status { return true }
        return false
    }
}
