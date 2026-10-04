import Foundation

enum ChatKind: Hashable {
    case user(userId: Int64)
    case bot(userId: Int64)
    case savedMessages(userId: Int64)
    case basicGroup(id: Int64)
    case supergroup(id: Int64)
    case channel(id: Int64)
    case secret(userId: Int64)

    var isChannel: Bool { if case .channel = self { return true }; return false }
    var isGroup: Bool {
        switch self {
        case .basicGroup, .supergroup: return true
        default: return false
        }
    }
    var isBot: Bool { if case .bot = self { return true }; return false }
    var privateUserId: Int64? {
        switch self {
        case .user(let id), .bot(let id), .savedMessages(let id), .secret(let id): return id
        default: return nil
        }
    }
}

/// Identifies a chat list: main, archive or a chat folder (Telegram "dialog filters").
enum ChatListKey: Hashable {
    case main
    case archive
    case folder(Int)
}

struct ChatPositionItem: Hashable {
    var order: Int64
    var isPinned: Bool
}

struct PhotoRef: Hashable {
    var small: FileRef
    var big: FileRef?
    var minithumbnail: Data?
}

struct ChatItem: Identifiable, Hashable {
    var id: Int64
    var title: String
    var kind: ChatKind
    var photo: PhotoRef?
    var positions: [ChatListKey: ChatPositionItem] = [:]
    var lastMessage: MessageItem?
    var unreadCount: Int = 0
    var unreadMentionCount: Int = 0
    var unreadReactionCount: Int = 0
    var isMarkedAsUnread: Bool = false
    var lastReadInboxMessageId: Int64 = 0
    var lastReadOutboxMessageId: Int64 = 0
    var isMuted: Bool = false
    var draftText: String?
    var accentColorId: Int = 0
    var hasProtectedContent: Bool = false
    var canBeDeletedForAllUsers: Bool = false
    var canBeDeletedOnlyForSelf: Bool = false
    var isVerified: Bool = false
    var isScam: Bool = false

    var isSavedMessages: Bool {
        if case .savedMessages = kind { return true }
        return false
    }

    /// Unread counter as the user should see it. In ghost mode the server still thinks messages are
    /// unread, so the local read marker (AyuGhostUtils.markReadLocally analogue) hides them.
    func visibleUnreadCount(localReadUntil: Int64) -> Int {
        if let last = lastMessage?.id, localReadUntil >= last { return 0 }
        return unreadCount
    }
}

struct UserItem: Identifiable, Hashable {
    var id: Int64
    var firstName: String
    var lastName: String
    var usernames: [String]
    var phoneNumber: String
    var photo: PhotoRef?
    var status: UserPresence
    var isBot: Bool
    var isPremium: Bool
    var isVerified: Bool
    var isContact: Bool
    var isDeleted: Bool
    var accentColorId: Int

    var fullName: String {
        if isDeleted { return L("HiddenName") }
        let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? L("HiddenName") : name
    }
    var username: String? { usernames.first }
}

enum UserPresence: Hashable {
    case online(expires: Int)
    case offline(wasOnline: Int)
    case recently, lastWeek, lastMonth, longTimeAgo, bot, unknown
}

struct UserProfileInfo: Hashable {
    var bio: String
    var commonGroupsCount: Int
    var canBeCalled: Bool
}

struct GroupInfo: Hashable {
    var memberCount: Int
    var description: String
    var username: String?
    var isChannel: Bool
    var inviteLink: String?
}

struct ChatFolderItem: Identifiable, Hashable {
    var id: Int
    var title: String
    var iconName: String?
}

struct SessionItem: Identifiable, Hashable {
    var id: Int64
    var title: String
    var device: String
    var location: String
    var lastActive: Int
    var isCurrent: Bool
    var isOfficial: Bool
}
