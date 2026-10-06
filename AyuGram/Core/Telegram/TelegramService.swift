/*
 * The iOS replacement for Telegram Android's MessagesController / ConnectionsManager /
 * UserConfig stack. Talks to TDLib (official Telegram Database Library) through TDLibKit.
 *
 * AyuGram hooks that lived in ConnectionsManager / MessagesController / SendMessagesHelper
 * on Android are implemented here explicitly (see "AyuGram hooks" marks).
 */

import Foundation
import Observation
import TDLibKit
import UIKit

enum AuthStep: Equatable {
    case loading
    case needsApiCredentials
    case phone
    case code(CodeInfo)
    case qr(link: String)
    case password(hint: String, hasRecoveryEmail: Bool)
    case registration
    case unsupported(String)
    case ready
    case loggingOut
}

struct CodeInfo: Equatable {
    var phone: String
    var deliveredVia: String
    var length: Int
    var canResend: Bool
}

enum ConnectionStatus: Equatable {
    case waitingForNetwork, connectingToProxy, connecting, updating, ready
}

enum TelegramServiceError: LocalizedError {
    case notReady
    var errorDescription: String? { L("ServiceNotReady") }
}

struct SupergroupLite: Hashable {
    var isChannel: Bool
    var memberCount: Int
    var username: String?
    var isVerified: Bool
    var isScam: Bool
    /// Whether the current user may post (channels: creator / admin with can_post_messages).
    var canPost: Bool
    var isMember: Bool
}

/// Events delivered to an open chat screen.
enum ChatEvent {
    case newMessage(MessageItem)
    case sendSucceeded(oldId: Int64, message: MessageItem)
    case sendFailed(oldId: Int64, message: MessageItem)
    case contentChanged(messageId: Int64, body: MessageBody)
    case edited(messageId: Int64, editDate: Int)
    case deleted(messageIds: [Int64], saved: [MessageItem])
    case interaction(messageId: Int64, reactions: [ReactionItem], views: Int, replies: Int)
    case pinned(messageId: Int64, isPinned: Bool)
    case readOutbox(messageId: Int64)
    case revisionsAdded(messageId: Int64)
}

@MainActor
protocol ChatEventSink: AnyObject {
    func handle(_ event: ChatEvent)
}

private final class WeakSink {
    weak var sink: ChatEventSink?
    init(_ sink: ChatEventSink) { self.sink = sink }
}

@MainActor
@Observable
final class TelegramService {
    static let shared = TelegramService()

    // MARK: Published state
    var authStep: AuthStep = .loading
    var connection: ConnectionStatus = .connecting
    var myUserId: Int64 = 0
    var chats: [Int64: ChatItem] = [:]
    var users: [Int64: UserItem] = [:]
    var basicGroupMembers: [Int64: Int] = [:]
    var supergroups: [Int64: SupergroupLite] = [:]
    var folders: [ChatFolderItem] = []
    /// chatId → "Alice is typing…"
    var chatActions: [Int64: String] = [:]
    var totalUnread: Int = 0

    let files = FileStore()

    // MARK: Internals
    @ObservationIgnored private var manager: TDLibClientManager?
    @ObservationIgnored private(set) var client: TDLibClient?
    @ObservationIgnored private var sinks: [Int64: [WeakSink]] = [:]
    @ObservationIgnored private var chatListLoadedAll: Set<ChatListKey> = []
    @ObservationIgnored private var chatListLoading: Set<ChatListKey> = []
    @ObservationIgnored private var scopeMuted: [String: Bool] = [:]
    @ObservationIgnored private var rawNotificationSettings: [Int64: ChatNotificationSettings] = [:]
    @ObservationIgnored private var chatActionTimers: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var activeChatId: Int64?
    @ObservationIgnored private var displayedMessageIds: [Int64: Set<Int64>] = [:]
    @ObservationIgnored private var pendingReadTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingReadDates: [Int64: [Int64: Foundation.Date]] = [:]
    @ObservationIgnored private var onlineTask: Task<Void, Never>?
    @ObservationIgnored private var ephemeralKeys: Set<String> = []
    @ObservationIgnored private var viewedEphemeral: [String: MessageItem] = [:]
    @ObservationIgnored private var credentials: ApiCredentials?
    @ObservationIgnored let config = AyuConfig.shared
    @ObservationIgnored let ayu = AyuMessagesController.shared

    private init() {
        files.downloader = { [weak self] id, priority in self?.startDownload(fileId: id, priority: priority) }
        files.canceller = { [weak self] id in
            guard let client = self?.client else { return }
            Task { _ = try? await client.cancelDownloadFile(fileId: id, onlyIfPending: false) }
        }
        ayu.fileResolver = { [weak self] id in
            guard let client = self?.client else { return nil }
            guard let f = try? await client.getFile(fileId: id), f.local.isDownloadingCompleted else { return nil }
            return f.local.path
        }
        _ = NotificationCenter.default.addObserver(forName: .ayuPrivacyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPendingReads(); self?.applyOnlineStatus() }
        }
        _ = NotificationCenter.default.addObserver(forName: .ayuGhostModeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPendingReads(); self?.applyOnlineStatus() }
        }
        _ = NotificationCenter.default.addObserver(forName: .ayuMessageEdited, object: nil, queue: .main) { [weak self] note in
            guard let chatId = note.userInfo?["chatId"] as? Int64, let messageId = note.userInfo?["messageId"] as? Int64 else { return }
            MainActor.assumeIsolated {
                self?.dispatch(chatId, .revisionsAdded(messageId: messageId))
                self?.ayu.cachedIncoming(chatId: chatId, messageId: messageId) { incoming in
                    if incoming { NotificationService.shared.onHistoryChange(chatId: chatId, edited: true) }
                }
                NotificationCenter.default.post(name: .ayuHistoryChanged, object: nil)
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard client == nil else { return }
        credentials = ApiCredentials.load()
        guard credentials != nil else {
            authStep = .needsApiCredentials
            return
        }
        createClient()
    }

    func provideCredentials(_ c: ApiCredentials) {
        c.save()
        credentials = c
        authStep = .loading
        if client == nil {
            createClient()
        } else {
            Task { await sendTdlibParameters() }
        }
    }

    private func createClient() {
        if manager == nil { manager = TDLibClientManager() }
        let newClient = manager!.createClient { [weak self] data, client in
            // Runs on the client's serial update queue: decode here, apply on main in order.
            do {
                let update = try client.decoder.decode(Update.self, from: data)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handle(update)
                        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            LocalAutomation.shared.ingest(object)
                        }
                    }
                }
            } catch {
                AppLog.debug("Undecodable update: \(error)")
            }
        }
        _ = try? newClient.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
        client = newClient
    }

    private func sendTdlibParameters() async {
        guard let client, let credentials, credentials.isValid else {
            authStep = .needsApiCredentials
            return
        }
        let support = AyuConstants.applicationSupport
        let dbDir = support.appendingPathComponent("tdlib", isDirectory: true)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let filesDir = caches.appendingPathComponent("tdlib_files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        do {
            try await client.setTdlibParameters(
                apiHash: credentials.apiHash,
                apiId: credentials.apiId,
                applicationVersion: "\(AyuConstants.appName) iOS \(version)",
                databaseDirectory: dbDir.path,
                databaseEncryptionKey: Data(),
                deviceModel: Self.deviceModel(),
                filesDirectory: filesDir.path,
                systemLanguageCode: Locale.preferredLanguages.first ?? "en",
                systemVersion: "iOS " + UIDevice.current.systemVersion,
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: true,
                useTestDc: false)
        } catch {
            AppLog.error("setTdlibParameters: \(error)")
            if let e = error as? TDLibKit.Error, e.code == 400 {
                // api_id/api_hash rejected
                ApiCredentials.clear()
                authStep = .needsApiCredentials
            }
        }
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let model = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return model.isEmpty ? UIDevice.current.model : model
    }

    /// Scene became active / inactive.
    func setAppActive(_ active: Bool) {
        isAppActive = active
        if !active { cancelPendingReads() }
        applyOnlineStatus()
    }

    // MARK: - AyuGram hooks: online status (ConnectionsManager: TL_account_updateStatus)

    private func applyOnlineStatus() {
        guard let client, authStep == .ready else { return }
        onlineTask?.cancel()
        let chatGhost = activeChatId.map { PrivacyPreferences.shared.isGhost($0) } ?? false
        let online = isAppActive && AppLock.shared.canShowContent && config.sendOnlinePackets && !chatGhost
        onlineTask = Task {
            _ = try? await client.setOption(name: "online", value: .optionValueBoolean(OptionValueBoolean(value: online)))
            if online && config.sendOfflinePacketAfterOnline {
                // "Immediate offline after online"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                _ = try? await client.setOption(name: "online", value: .optionValueBoolean(OptionValueBoolean(value: false)))
            }
        }
    }

    /// Called after the user sent something. The server may mark the account online on activity,
    /// so with "Immediate offline after online" we re-send the offline status.
    private func afterOwnActivity() {
        let ghost = activeChatId.map { PrivacyPreferences.shared.isGhost($0) } ?? config.isGhostModeActive
        guard let client, ghost || config.sendOfflinePacketAfterOnline else { return }
        Task {
            _ = try? await client.setOption(name: "online", value: .optionValueBoolean(OptionValueBoolean(value: false)))
        }
    }

    // MARK: - Authorization

    func sendPhone(_ phone: String) async throws {
        guard let client else { return }
        let settings = PhoneNumberAuthenticationSettings(allowFlashCall: false, allowMissedCall: false, allowSmsRetrieverApi: false,
                                                         authenticationTokens: [], firebaseAuthenticationSettings: nil,
                                                         hasUnknownPhoneNumber: false, isCurrentPhoneNumber: false)
        try await client.setAuthenticationPhoneNumber(phoneNumber: phone, settings: settings)
    }

    func requestQr() async throws {
        guard let client else { return }
        try await client.requestQrCodeAuthentication(otherUserIds: [])
    }

    func sendCode(_ code: String) async throws {
        guard let client else { return }
        try await client.checkAuthenticationCode(code: code)
    }

    func resendCode() async throws {
        guard let client else { return }
        try await client.resendAuthenticationCode(reason: .resendCodeReasonUserRequest)
    }

    func sendPassword(_ password: String) async throws {
        guard let client else { return }
        try await client.checkAuthenticationPassword(password: password)
    }

    func register(firstName: String, lastName: String) async throws {
        guard let client else { return }
        try await client.registerUser(disableNotification: false, firstName: firstName, lastName: lastName)
    }

    func logOut() async {
        guard let client else { return }
        authStep = .loggingOut
        _ = try? await client.logOut()
    }

    private func handleAuthorization(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            authStep = .loading
            Task { await sendTdlibParameters() }
        case .authorizationStateWaitPhoneNumber:
            authStep = .phone
        case .authorizationStateWaitCode(let w):
            let info = w.codeInfo
            authStep = .code(CodeInfo(phone: info.phoneNumber, deliveredVia: Self.describe(info.type),
                                      length: Self.codeLength(info.type), canResend: info.nextType != nil))
        case .authorizationStateWaitOtherDeviceConfirmation(let w):
            authStep = .qr(link: w.link)
        case .authorizationStateWaitPassword(let w):
            authStep = .password(hint: w.passwordHint, hasRecoveryEmail: w.hasRecoveryEmailAddress)
        case .authorizationStateWaitRegistration:
            authStep = .registration
        case .authorizationStateWaitEmailAddress, .authorizationStateWaitEmailCode:
            authStep = .unsupported(L("AuthEmailUnsupported"))
        case .authorizationStateWaitPremiumPurchase:
            authStep = .unsupported(L("AuthPremiumUnsupported"))
        case .authorizationStateReady:
            authStep = .ready
            Task { await onReady() }
        case .authorizationStateLoggingOut, .authorizationStateClosing:
            authStep = .loggingOut
        case .authorizationStateClosed:
            // TDLib instance is finished (log out) — start a fresh one.
            resetState()
            client = nil
            createClient()
        }
    }

    private func onReady() async {
        guard let client else { return }
        if let me = try? await client.getMe() {
            setMyUserId(me.id)
            users[me.id] = TDConvert.user(me)
            AyuSyncController.shared.accountReady(userId: me.id)
        }
        applyOnlineStatus()
        await loadChats(.main)
    }

    private func setMyUserId(_ id: Int64) {
        guard id != 0, id != myUserId else { return }
        myUserId = id
        PrivacyPreferences.shared.selectAccount(id)
        LocalReadStore.shared.selectAccount(id)
        LocalAutomation.shared.selectAccount(id)
        AppLock.shared.accountChanged()
        ayu.userId = id
        // Chats may have arrived before my_id was known.
        if var chat = chats[id], case .user = chat.kind {
            chat.kind = .savedMessages(userId: id)
            chats[id] = chat
        }
    }

    private func resetState() {
        chatActionTimers.values.forEach { $0.cancel() }
        chatActionTimers = [:]
        sinks = [:]
        scopeMuted = [:]
        rawNotificationSettings = [:]
        totalUnread = 0
        AppRouter.shared.chatPath = []
        AppRouter.shared.selectedTab = 0
        chats = [:]
        users = [:]
        basicGroupMembers = [:]
        supergroups = [:]
        folders = []
        chatActions = [:]
        myUserId = 0
        cancelPendingReads(); activeChatId = nil; displayedMessageIds = [:]; ephemeralKeys = []; viewedEphemeral = [:]
        PrivacyPreferences.shared.selectAccount(0)
        LocalReadStore.shared.selectAccount(0)
        LocalAutomation.shared.selectAccount(0)
        AppLock.shared.accountChanged()
        chatListLoadedAll = []
        chatListLoading = []
        files.reset()
    }

    private static func describe(_ t: AuthenticationCodeType) -> String {
        switch t {
        case .authenticationCodeTypeTelegramMessage: return L("CodeViaTelegram")
        case .authenticationCodeTypeSms, .authenticationCodeTypeSmsWord, .authenticationCodeTypeSmsPhrase: return L("CodeViaSms")
        case .authenticationCodeTypeCall, .authenticationCodeTypeFlashCall, .authenticationCodeTypeMissedCall: return L("CodeViaCall")
        case .authenticationCodeTypeFragment: return L("CodeViaFragment")
        default: return L("CodeViaSms")
        }
    }

    private static func codeLength(_ t: AuthenticationCodeType) -> Int {
        switch t {
        case .authenticationCodeTypeTelegramMessage(let x): return x.length
        case .authenticationCodeTypeSms(let x): return x.length
        case .authenticationCodeTypeCall(let x): return x.length
        case .authenticationCodeTypeFragment(let x): return x.length
        default: return 5
        }
    }

    // MARK: - Update dispatch

    private func handle(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let u):
            handleAuthorization(u.authorizationState)

        case .updateConnectionState(let u):
            switch u.state {
            case .connectionStateWaitingForNetwork: connection = .waitingForNetwork
            case .connectionStateConnectingToProxy: connection = .connectingToProxy
            case .connectionStateConnecting: connection = .connecting
            case .connectionStateUpdating: connection = .updating
            case .connectionStateReady: connection = .ready
            }

        case .updateOption(let u):
            if u.name == "my_id", case .optionValueInteger(let v) = u.value {
                setMyUserId(v.value.rawValue)
            }

        // Users & groups
        case .updateUser(let u):
            let item = TDConvert.user(u.user)
            users[u.user.id] = item
            if item.isBot, var chat = chats[u.user.id], case .user = chat.kind {
                chat.kind = .bot(userId: u.user.id)
                chats[u.user.id] = chat
            }
        case .updateUserStatus(let u):
            users[u.userId]?.status = users[u.userId]?.isBot == true ? .bot : TDConvert.presence(u.status)
        case .updateBasicGroup(let u):
            basicGroupMembers[u.basicGroup.id] = u.basicGroup.memberCount
        case .updateSupergroup(let u):
            let s = u.supergroup
            var canPost = !s.isChannel
            var isMember = true
            switch s.status {
            case .chatMemberStatusCreator(let c): canPost = true; isMember = c.isMember
            case .chatMemberStatusAdministrator(let a): canPost = !s.isChannel || a.rights.canPostMessages
            case .chatMemberStatusRestricted(let r): canPost = r.permissions.canSendBasicMessages && !s.isChannel; isMember = r.isMember
            case .chatMemberStatusLeft, .chatMemberStatusBanned: canPost = false; isMember = false
            case .chatMemberStatusMember: break
            }
            supergroups[s.id] = SupergroupLite(isChannel: s.isChannel, memberCount: s.memberCount,
                                               username: s.usernames?.activeUsernames.first,
                                               isVerified: s.verificationStatus?.isVerified ?? false,
                                               isScam: s.verificationStatus?.isScam ?? false,
                                               canPost: canPost, isMember: isMember)

        // Chats
        case .updateNewChat(let u):
            chats[u.chat.id] = makeChatItem(u.chat)
            if let last = chats[u.chat.id]?.lastMessage { ayu.onMessagesSeen([last]) }
        case .updateChatTitle(let u):
            chats[u.chatId]?.title = u.title
        case .updateChatPhoto(let u):
            chats[u.chatId]?.photo = u.photo.map(PhotoRef.init)
        case .updateChatLastMessage(let u):
            let item = u.lastMessage.map(convert)
            chats[u.chatId]?.lastMessage = item
            for p in u.positions { applyPosition(chatId: u.chatId, p) }
            if let item { ayu.onMessagesSeen([item]) }
        case .updateChatPosition(let u):
            applyPosition(chatId: u.chatId, u.position)
        case .updateChatReadInbox(let u):
            chats[u.chatId]?.unreadCount = u.unreadCount
            chats[u.chatId]?.lastReadInboxMessageId = u.lastReadInboxMessageId
        case .updateChatReadOutbox(let u):
            chats[u.chatId]?.lastReadOutboxMessageId = u.lastReadOutboxMessageId
            dispatch(u.chatId, .readOutbox(messageId: u.lastReadOutboxMessageId))
        case .updateChatUnreadMentionCount(let u):
            chats[u.chatId]?.unreadMentionCount = u.unreadMentionCount
        case .updateChatUnreadReactionCount(let u):
            chats[u.chatId]?.unreadReactionCount = u.unreadReactionCount
        case .updateChatIsMarkedAsUnread(let u):
            chats[u.chatId]?.isMarkedAsUnread = u.isMarkedAsUnread
        case .updateChatDraftMessage(let u):
            chats[u.chatId]?.draftText = TDConvert.draftText(u.draftMessage)
            for p in u.positions { applyPosition(chatId: u.chatId, p) }
        case .updateChatNotificationSettings(let u):
            rawNotificationSettings[u.chatId] = u.notificationSettings
            if let kind = chats[u.chatId]?.kind {
                chats[u.chatId]?.isMuted = isMuted(u.notificationSettings, kind: kind)
            }
        case .updateScopeNotificationSettings(let u):
            scopeMuted[Self.scopeKey(u.scope)] = u.notificationSettings.muteFor > 0
            recomputeMutes()
        case .updateChatHasProtectedContent(let u):
            chats[u.chatId]?.hasProtectedContent = u.hasProtectedContent
        case .updateChatFolders(let u):
            folders = u.chatFolders.map { ChatFolderItem(id: $0.id, title: $0.name.text.text, iconName: $0.icon.name) }
        case .updateChatAction(let u):
            handleChatAction(u)
        case .updateUnreadMessageCount(let u):
            if case .chatListMain = u.chatList { totalUnread = u.unreadUnmutedCount }

        // Messages
        case .updateNewMessage(let u):
            let item = convert(u.message)
            ayu.onMessagesSeen([item])
            LocalAutomation.shared.sent(item)
            dispatch(item.chatId, .newMessage(item))
            NotificationService.shared.onNewMessage(item, chat: chats[item.chatId], appActive: isAppActive, title: chatTitle(item.chatId))
        case .updateMessageSendSucceeded(let u):
            let item = convert(u.message)
            ayu.onMessageSendSucceeded(oldId: u.oldMessageId, message: item)
            LocalAutomation.shared.sent(item)
            dispatch(item.chatId, .sendSucceeded(oldId: u.oldMessageId, message: item))
        case .updateMessageSendFailed(let u):
            dispatch(u.message.chatId, .sendFailed(oldId: u.oldMessageId, message: convert(u.message)))
        case .updateMessageContent(let u):
            // --- AyuGram hook: edits history (AyuMessagesController.onMessageEdited)
            let body = TDConvert.body(u.newContent, sender: .chat(u.chatId), names: nameOf)
            AyuFilter.shared.invalidate(dialogId: u.chatId, messageId: u.messageId)
            ayu.onMessageContentChanged(chatId: u.chatId, messageId: u.messageId, newBody: body, context: ayuContext(u.chatId))
            dispatch(u.chatId, .contentChanged(messageId: u.messageId, body: body))
        case .updateMessageEdited(let u):
            ayu.onMessageEditDateChanged(chatId: u.chatId, messageId: u.messageId, editDate: u.editDate)
            dispatch(u.chatId, .edited(messageId: u.messageId, editDate: u.editDate))
        case .updateDeleteMessages(let u):
            handleDeleted(u)
        case .updateMessageInteractionInfo(let u):
            dispatch(u.chatId, .interaction(messageId: u.messageId, reactions: TDConvert.reactions(u.interactionInfo),
                                            views: u.interactionInfo?.viewCount ?? 0,
                                            replies: u.interactionInfo?.replyInfo?.replyCount ?? 0))
        case .updateMessageIsPinned(let u):
            dispatch(u.chatId, .pinned(messageId: u.messageId, isPinned: u.isPinned))

        // Files
        case .updateFile(let u):
            let f = u.file
            files.update(id: f.id, localPath: f.local.path, completed: f.local.isDownloadingCompleted,
                         downloaded: f.local.downloadedSize, size: f.size > 0 ? f.size : f.expectedSize,
                         isActive: f.local.isDownloadingActive)
            if f.local.isDownloadingCompleted {
                for message in viewedEphemeral.values where message.body.mainFile?.id == f.id { preserveViewed(message) }
            }

        default:
            break
        }
    }

    // MARK: - AyuGram hook: deleted messages (MessagesController → AyuMessagesController.onMessageDeleted)

    private func handleDeleted(_ u: UpdateDeleteMessages) {
        if u.fromCache { return } // only evicted from TDLib's memory, not deleted
        guard u.isPermanent else {
            dispatch(u.chatId, .deleted(messageIds: u.messageIds, saved: []))
            return
        }
        let chatId = u.chatId
        let ids = u.messageIds
        ayu.onMessagesDeleted(chatId: chatId, messageIds: ids, context: ayuContext(chatId)) { [weak self] saved in
            self?.dispatch(chatId, .deleted(messageIds: ids, saved: saved))
            if saved.contains(where: { !$0.isOutgoing }) { NotificationService.shared.onHistoryChange(chatId: chatId, edited: false) }
            NotificationCenter.default.post(name: .ayuHistoryChanged, object: nil)
        }
    }

    func ayuContext(_ chatId: Int64) -> AyuDialogContext {
        guard let chat = chats[chatId] else { return AyuDialogContext(isBot: false, kind: .privateChat) }
        switch chat.kind {
        case .user, .savedMessages, .secret:
            return AyuDialogContext(isBot: false, kind: .privateChat)
        case .bot:
            return AyuDialogContext(isBot: true, kind: .privateChat)
        case .basicGroup:
            return AyuDialogContext(isBot: false, kind: .privateGroup)
        case .supergroup(let id):
            return AyuDialogContext(isBot: false, kind: supergroups[id]?.username != nil ? .publicGroup : .privateGroup)
        case .channel(let id):
            return AyuDialogContext(isBot: false, kind: supergroups[id]?.username != nil ? .publicChannel : .privateChannel)
        }
    }

    // MARK: - Chat helpers

    private func makeChatItem(_ c: Chat) -> ChatItem {
        let kind: ChatKind
        switch c.type {
        case .chatTypePrivate(let p):
            if p.userId == myUserId && myUserId != 0 { kind = .savedMessages(userId: p.userId) }
            else if users[p.userId]?.isBot == true { kind = .bot(userId: p.userId) }
            else { kind = .user(userId: p.userId) }
        case .chatTypeBasicGroup(let g): kind = .basicGroup(id: g.basicGroupId)
        case .chatTypeSupergroup(let s): kind = s.isChannel ? .channel(id: s.supergroupId) : .supergroup(id: s.supergroupId)
        case .chatTypeSecret(let s): kind = .secret(userId: s.userId)
        }
        rawNotificationSettings[c.id] = c.notificationSettings
        var item = ChatItem(id: c.id, title: c.title, kind: kind)
        item.photo = c.photo.map(PhotoRef.init)
        for p in c.positions {
            item.positions[TDConvert.chatListKey(p.list)] = ChatPositionItem(order: p.order.rawValue, isPinned: p.isPinned)
        }
        item.lastMessage = c.lastMessage.map(convert)
        item.unreadCount = c.unreadCount
        item.unreadMentionCount = c.unreadMentionCount
        item.unreadReactionCount = c.unreadReactionCount
        item.isMarkedAsUnread = c.isMarkedAsUnread
        item.lastReadInboxMessageId = c.lastReadInboxMessageId
        item.lastReadOutboxMessageId = c.lastReadOutboxMessageId
        item.isMuted = isMuted(c.notificationSettings, kind: kind)
        item.draftText = TDConvert.draftText(c.draftMessage)
        item.accentColorId = c.accentColorId
        item.hasProtectedContent = c.hasProtectedContent
        item.canBeDeletedForAllUsers = c.canBeDeletedForAllUsers
        item.canBeDeletedOnlyForSelf = c.canBeDeletedOnlyForSelf
        return item
    }

    private func applyPosition(chatId: Int64, _ p: ChatPosition) {
        let key = TDConvert.chatListKey(p.list)
        if p.order.rawValue == 0 {
            chats[chatId]?.positions[key] = nil
        } else {
            chats[chatId]?.positions[key] = ChatPositionItem(order: p.order.rawValue, isPinned: p.isPinned)
        }
    }

    private static func scopeKey(_ s: NotificationSettingsScope) -> String {
        switch s {
        case .notificationSettingsScopePrivateChats: return "private"
        case .notificationSettingsScopeGroupChats: return "group"
        case .notificationSettingsScopeChannelChats: return "channel"
        }
    }

    private func isMuted(_ s: ChatNotificationSettings, kind: ChatKind) -> Bool {
        if !s.useDefaultMuteFor { return s.muteFor > 0 }
        switch kind {
        case .channel: return scopeMuted["channel"] ?? false
        case .basicGroup, .supergroup: return scopeMuted["group"] ?? false
        default: return scopeMuted["private"] ?? false
        }
    }

    private func recomputeMutes() {
        for (id, settings) in rawNotificationSettings {
            guard let kind = chats[id]?.kind else { continue }
            let muted = isMuted(settings, kind: kind)
            if chats[id]?.isMuted != muted { chats[id]?.isMuted = muted }
        }
    }

    private func handleChatAction(_ u: UpdateChatAction) {
        let chatId = u.chatId
        chatActionTimers[chatId]?.cancel()
        if case .chatActionCancel = u.action {
            chatActions[chatId] = nil
            return
        }
        let verb: String
        switch u.action {
        case .chatActionTyping: verb = L("ActionTyping")
        case .chatActionRecordingVoiceNote, .chatActionUploadingVoiceNote: verb = L("ActionRecordingVoice")
        case .chatActionRecordingVideo, .chatActionUploadingVideo, .chatActionRecordingVideoNote, .chatActionUploadingVideoNote: verb = L("ActionRecordingVideo")
        case .chatActionUploadingPhoto: verb = L("ActionSendingPhoto")
        case .chatActionUploadingDocument: verb = L("ActionSendingFile")
        case .chatActionChoosingSticker: verb = L("ActionChoosingSticker")
        default: verb = L("ActionTyping")
        }
        let isPrivate = chats[chatId]?.kind.privateUserId != nil
        chatActions[chatId] = isPrivate ? verb : "\(nameOf(SenderRef(u.senderId))) \(verb)"
        chatActionTimers[chatId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.chatActions[chatId] = nil
        }
    }

    // MARK: - Names

    func nameOf(_ sender: SenderRef) -> String {
        switch sender {
        case .user(let id):
            if id == myUserId, myUserId != 0 { return users[id]?.firstName ?? L("You") }
            return users[id]?.fullName ?? L("HiddenName")
        case .chat(let id):
            return chats[id]?.title ?? ""
        }
    }

    func chatTitle(_ chatId: Int64) -> String {
        guard let chat = chats[chatId] else { return "" }
        if case .savedMessages = chat.kind { return L("SavedMessages") }
        return chat.title
    }

    func convert(_ m: Message) -> MessageItem {
        let item = TDConvert.message(m, names: nameOf)
        LocalAutomation.shared.rememberCallMessage(item)
        if let data = try? JSONEncoder().encode(m), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let content = object["content"] as? [String: Any] ?? [:]
            let value = object["self_destruct_type"] ?? content["self_destruct_type"]
            if let value, !(value is NSNull) { ephemeralKeys.insert("\(item.chatId):\(item.id)") }
        }
        return item
    }

    // MARK: - Chat list

    func sortedChatIds(in list: ChatListKey) -> [Int64] {
        chats.values
            .compactMap { chat -> (Int64, Int64)? in
                guard let pos = chat.positions[list] else { return nil }
                return (chat.id, pos.order)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func loadChats(_ list: ChatListKey, limit: Int = 50) async {
        guard let client, !chatListLoadedAll.contains(list), !chatListLoading.contains(list) else { return }
        chatListLoading.insert(list)
        defer { chatListLoading.remove(list) }
        do {
            try await client.loadChats(chatList: TDConvert.tdChatList(list), limit: limit)
        } catch {
            if let e = error as? TDLibKit.Error, e.code == 404 {
                chatListLoadedAll.insert(list)
            } else {
                AppLog.error("loadChats: \(error)")
            }
        }
    }

    func isChatListFullyLoaded(_ list: ChatListKey) -> Bool { chatListLoadedAll.contains(list) }

    // MARK: - Chat screen subscriptions

    func subscribe(chatId: Int64, _ sink: ChatEventSink) {
        sinks[chatId, default: []].removeAll { $0.sink == nil || $0.sink === sink }
        sinks[chatId, default: []].append(WeakSink(sink))
    }

    func unsubscribe(chatId: Int64, _ sink: ChatEventSink) {
        sinks[chatId]?.removeAll { $0.sink == nil || $0.sink === sink }
    }

    private func dispatch(_ chatId: Int64, _ event: ChatEvent) {
        guard let list = sinks[chatId] else { return }
        for s in list { s.sink?.handle(event) }
    }

    func openChat(_ chatId: Int64) async {
        guard let chat = chats[chatId], AppLock.shared.visible(chat), AppLock.shared.canShowContent else { return }
        activeChatId = chatId; applyOnlineStatus()
        _ = try? await client?.openChat(chatId: chatId)
    }

    func closeChat(_ chatId: Int64) async {
        displayedMessageIds[chatId] = nil
        pendingReadTasks.removeValue(forKey: chatId)?.cancel(); pendingReadDates[chatId] = nil
        if activeChatId == chatId { activeChatId = nil; applyOnlineStatus() }
        _ = try? await client?.closeChat(chatId: chatId)
    }

    func history(chatId: Int64, from fromMessageId: Int64, offset: Int = 0, limit: Int = 50, onlyLocal: Bool = false) async throws -> [MessageItem] {
        guard let client else { return [] }
        let result = try await client.getChatHistory(chatId: chatId, fromMessageId: fromMessageId, limit: limit, offset: offset, onlyLocal: onlyLocal)
        let items = (result.messages ?? []).map(convert)
        ayu.onMessagesSeen(items)
        return items
    }

    func message(chatId: Int64, id: Int64) async -> MessageItem? {
        guard let client, let m = try? await client.getMessage(chatId: chatId, messageId: id) else { return nil }
        let item = convert(m)
        ayu.onMessagesSeen([item])
        return item
    }

    // MARK: - AyuGram hook: read packets (ConnectionsManager: TL_messages_readHistory …)

    /// Marks messages as viewed. With "Don't read messages" nothing is sent to the server;
    /// the chat is only marked read locally (AyuGhostUtils.markReadLocally).
    func cancelPendingReads() {
        pendingReadTasks.values.forEach { $0.cancel() }; pendingReadTasks = [:]; pendingReadDates = [:]
    }

    func mediaOpened(_ message: MessageItem) {
        let ephemeral = message.selfDestructIn > 0 || ephemeralKeys.contains(message.historyKey)
        if ephemeral { viewedEphemeral[message.historyKey] = message }
        if let client {
            Task { _ = try? await client.openMessageContent(chatId: message.chatId, messageId: message.id) }
        }
        preserveViewed(message)
    }

    func preserveViewed(_ message: MessageItem) {
        guard PrivacyPreferences.shared.snapshot.keepViewedEphemeralMedia,
              viewedEphemeral[message.historyKey] != nil, let file = message.body.mainFile else { return }
        // Only a fully downloaded file is copied. Expired or inaccessible media is never recoverable.
        guard let path = files.path(for: file), FileManager.default.fileExists(atPath: path) else { return }
        ayu.preserveViewedMedia(message, localPath: path)
    }

    func markViewed(chatId: Int64, messageIds: [Int64]) {
        guard isAppActive, AppLock.shared.canShowContent, let maxId = messageIds.max() else { return }
        let privacy = PrivacyPreferences.shared
        guard privacy.sendsRead(chatId) else {
            LocalReadStore.shared.markRead(chatId: chatId, until: maxId); return
        }
        let delay = privacy.chat(chatId).readDelay
        guard delay >= 0 else { return }
        if delay == 0 { sendViewed(chatId: chatId, messageIds: messageIds); return }
        let deadline = Date().addingTimeInterval(Double(min(delay, 3600)))
        for id in messageIds where pendingReadDates[chatId]?[id] == nil { pendingReadDates[chatId, default: [:]][id] = deadline }
        guard pendingReadTasks[chatId] == nil else { return }
        let account = myUserId
        pendingReadTasks[chatId] = Task { [weak self] in
            while let self, !Task.isCancelled, let next = self.pendingReadDates[chatId]?.values.min() {
                let wait = max(0, next.timeIntervalSinceNow)
                do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled, self.myUserId == account, self.activeChatId == chatId,
                      self.isAppActive, AppLock.shared.canShowContent, privacy.sendsRead(chatId), privacy.chat(chatId).readDelay == delay else { return }
                let ids = self.pendingReadDates[chatId]?.filter { $0.value <= Date() }.map(\.key) ?? []
                for id in ids { self.pendingReadDates[chatId]?[id] = nil }
                self.sendViewed(chatId: chatId, messageIds: ids)
                if self.pendingReadDates[chatId]?.isEmpty != false {
                    self.pendingReadDates[chatId] = nil; self.pendingReadTasks[chatId] = nil; return
                }
            }
        }
    }

    private func sendViewed(chatId: Int64, messageIds: [Int64]) {
        guard let client, let maxId = messageIds.max() else { return }
        Task {
            do {
                try await client.viewMessages(chatId: chatId, forceRead: false, messageIds: messageIds, source: .messageSourceChatHistory)
                AyuSyncController.shared.syncRead(chatId: chatId, untilId: maxId, unread: 0)
            } catch { AppLog.debug("Read status: \(error)") }
        }
    }

    /// "Read until here" (OPTION_READ_UNTIL) — explicitly allowed read packet in ghost mode
    /// (AyuGhostUtils.markReadOnServer).
    func markReadOnServer(chatId: Int64, untilMessageId: Int64) async {
        guard let client else { return }
        pendingReadTasks.removeValue(forKey: chatId)?.cancel(); pendingReadDates[chatId] = nil
        do { try await client.viewMessages(chatId: chatId, forceRead: true, messageIds: [untilMessageId], source: .messageSourceChatHistory) }
        catch { AppLog.debug("Manual read: \(error)"); return }
        LocalReadStore.shared.markRead(chatId: chatId, until: untilMessageId)
        AyuSyncController.shared.syncRead(chatId: chatId, untilId: untilMessageId, unread: 0)
    }

    // MARK: - AyuGram hook: typing (ConnectionsManager: TL_messages_setTyping)

    func sendTyping(chatId: Int64) {
        guard PrivacyPreferences.shared.sendsTyping(chatId), AppLock.shared.canShowContent, let client else { return }
        Task { _ = try? await client.sendChatAction(action: .chatActionTyping, businessConnectionId: nil, chatId: chatId, topicId: nil) }
    }

    // MARK: - Sending (SendMessagesHelper hooks: scheduled sending, read after send)

    private func sendOptions() -> MessageSendOptions {
        var scheduling: MessageSchedulingState?
        if config.useScheduledMessages {
            // "If the schedule_date is less than 10 seconds in the future, the message will be sent immediately".
            // AyuGram: now + 10 + 1 second safety window.
            let date = Int(Date().timeIntervalSince1970) + 12
            scheduling = .messageSchedulingStateSendAtDate(MessageSchedulingStateSendAtDate(repeatPeriod: 0, sendDate: date))
        }
        return MessageSendOptions(allowPaidBroadcast: false, disableNotification: false, effectId: TdInt64(0),
                                  fromBackground: false, onlyPreview: false, paidMessageStarCount: 0,
                                  protectContent: false, schedulingState: scheduling, sendingId: 0,
                                  suggestedPostInfo: nil, updateOrderOfInstalledStickerSets: false)
    }

    private func replyTo(_ messageId: Int64?) -> InputMessageReplyTo? {
        guard let messageId, messageId != 0 else { return nil }
        return .inputMessageReplyToMessage(InputMessageReplyToMessage(checklistTaskId: 0, messageId: messageId, pollOptionId: "", quote: nil))
    }

    @discardableResult
    func send(chatId: Int64, content: InputMessageContent, replyToMessageId: Int64?) async throws -> MessageItem? {
        guard let client, authStep == .ready else { throw TelegramServiceError.notReady }
        // Remember the newest incoming message before our own message becomes the chat's last one.
        let lastIncoming = chats[chatId]?.lastMessage.flatMap { $0.isOutgoing ? nil : $0.id }
        let sent = try await client.sendMessage(chatId: chatId, inputMessageContent: content, options: sendOptions(),
                                                replyMarkup: nil, replyTo: replyTo(replyToMessageId), topicId: nil)
        afterSend(chatId: chatId, lastIncoming: lastIncoming)
        return convert(sent)
    }

    func sendText(chatId: Int64, text: RichText, replyToMessageId: Int64?) async throws {
        let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: text.formattedText))
        try await send(chatId: chatId, content: content, replyToMessageId: replyToMessageId)
    }

    func sendPhoto(chatId: Int64, path: String, width: Int, height: Int, caption: String, replyToMessageId: Int64?) async throws {
        let photo = InputPhoto(addedStickerFileIds: [], height: height, photo: .inputFileLocal(InputFileLocal(path: path)),
                               thumbnail: nil, video: nil, width: width)
        let content = InputMessageContent.inputMessagePhoto(InputMessagePhoto(caption: FormattedText(entities: [], text: caption),
                                                                              hasSpoiler: false, photo: photo,
                                                                              selfDestructType: nil, showCaptionAboveMedia: false))
        try await send(chatId: chatId, content: content, replyToMessageId: replyToMessageId)
    }

    func sendDocument(chatId: Int64, path: String, caption: String, replyToMessageId: Int64?) async throws {
        let doc = InputDocument(disableContentTypeDetection: false, document: .inputFileLocal(InputFileLocal(path: path)), thumbnail: nil)
        let content = InputMessageContent.inputMessageDocument(InputMessageDocument(caption: FormattedText(entities: [], text: caption), document: doc))
        try await send(chatId: chatId, content: content, replyToMessageId: replyToMessageId)
    }

    /// "Send read status after reply" + "Immediate offline".
    private func afterSend(chatId: Int64, lastIncoming: Int64?) {
        afterOwnActivity()
        guard !PrivacyPreferences.shared.sendsRead(chatId), config.markReadAfterSend, PrivacyPreferences.shared.chat(chatId).readDelay == 0, let lastIncoming else { return }
        Task { await markReadOnServer(chatId: chatId, untilMessageId: lastIncoming) }
    }

    func editText(chatId: Int64, messageId: Int64, text: RichText) async throws {
        guard let client, authStep == .ready else { throw TelegramServiceError.notReady }
        let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: false, linkPreviewOptions: nil, text: text.formattedText))
        _ = try await client.editMessageText(chatId: chatId, inputMessageContent: content, messageId: messageId, replyMarkup: nil)
    }

    func delete(chatId: Int64, messageIds: [Int64], revoke: Bool) async throws {
        guard let client, authStep == .ready else { throw TelegramServiceError.notReady }
        // --- AyuGram hook: own deletions are not saved as "deleted" (AyuState.permitDeleteMessage)
        AyuState.shared.permitDeleteMessages(chatId: chatId, messageIds: messageIds)
        do { try await client.deleteMessages(chatId: chatId, messageIds: messageIds, revoke: revoke) }
        catch {
            messageIds.forEach { AyuState.shared.messageDeleted(chatId: chatId, messageId: $0) }
            throw error
        }
    }

    func forward(messageIds: [Int64], from fromChatId: Int64, to chatId: Int64) async throws {
        guard let client else { return }
        _ = try await client.forwardMessages(chatId: chatId, fromChatId: fromChatId, messageIds: messageIds, options: sendOptions(),
                                             removeCaption: false, sendCopy: false, topicId: nil)
        afterOwnActivity()
    }

    func clearHistory(chatId: Int64, revoke: Bool) async throws {
        guard let client else { return }
        AyuState.shared.permitDeleteWholeChat(chatId: chatId)
        try await client.deleteChatHistory(chatId: chatId, removeFromChatList: false, revoke: revoke)
    }

    func leave(chatId: Int64) async throws {
        guard let client else { return }
        AyuState.shared.permitDeleteWholeChat(chatId: chatId)
        if let chat = chats[chatId], chat.kind.privateUserId != nil {
            try await client.deleteChat(chatId: chatId)
        } else {
            try await client.leaveChat(chatId: chatId)
        }
    }

    func setPinned(chatId: Int64, list: ChatListKey, pinned: Bool) async {
        _ = try? await client?.toggleChatIsPinned(chatId: chatId, chatList: TDConvert.tdChatList(list), isPinned: pinned)
    }

    func setArchived(chatId: Int64, archived: Bool) async {
        _ = try? await client?.addChatToList(chatId: chatId, chatList: archived ? .chatListArchive : .chatListMain)
    }

    func setMuted(chatId: Int64, muted: Bool) async {
        guard let client, let s = rawNotificationSettings[chatId] else { return }
        let new = ChatNotificationSettings(
            disableMentionNotifications: s.disableMentionNotifications,
            disablePinnedMessageNotifications: s.disablePinnedMessageNotifications,
            muteFor: muted ? Int(Int32.max) : 0, muteStories: s.muteStories,
            showPreview: s.showPreview, showStoryPoster: s.showStoryPoster, soundId: s.soundId, storySoundId: s.storySoundId,
            useDefaultDisableMentionNotifications: s.useDefaultDisableMentionNotifications,
            useDefaultDisablePinnedMessageNotifications: s.useDefaultDisablePinnedMessageNotifications,
            useDefaultMuteFor: false, useDefaultMuteStories: s.useDefaultMuteStories,
            useDefaultShowPreview: s.useDefaultShowPreview, useDefaultShowStoryPoster: s.useDefaultShowStoryPoster,
            useDefaultSound: s.useDefaultSound, useDefaultStorySound: s.useDefaultStorySound)
        _ = try? await client.setChatNotificationSettings(chatId: chatId, notificationSettings: new)
    }

    func markChatUnread(chatId: Int64, unread: Bool) async {
        if !unread {
            // Ghost-aware "mark as read"
            if let last = chats[chatId]?.lastMessage?.id {
                if PrivacyPreferences.shared.sendsRead(chatId) && PrivacyPreferences.shared.chat(chatId).readDelay == 0 {
                    await markReadOnServer(chatId: chatId, untilMessageId: last)
                } else {
                    LocalReadStore.shared.markRead(chatId: chatId, until: last)
                }
            }
            _ = try? await client?.toggleChatIsMarkedAsUnread(chatId: chatId, isMarkedAsUnread: false)
        } else {
            _ = try? await client?.toggleChatIsMarkedAsUnread(chatId: chatId, isMarkedAsUnread: true)
        }
    }

    func saveDraft(chatId: Int64, text: String) async {
        guard let client else { return }
        let draft: DraftMessage? = text.isEmpty ? nil : DraftMessage(
            content: .draftMessageContentText(DraftMessageContentText(linkPreviewOptions: nil, text: FormattedText(entities: [], text: text))),
            date: Int(Date().timeIntervalSince1970), effectId: TdInt64(0), replyTo: nil, suggestedPostInfo: nil)
        _ = try? await client.setChatDraftMessage(chatId: chatId, draftMessage: draft, topicId: nil)
    }

    // MARK: - Search / contacts

    func searchChats(_ query: String) async -> [Int64] {
        guard let client, !query.isEmpty else { return [] }
        var ids: [Int64] = []
        if let local = try? await client.searchChats(limit: 30, query: query, typeFilter: nil) { ids += local.chatIds }
        if let remote = try? await client.searchPublicChats(query: query, typeFilter: nil) {
            ids += remote.chatIds.filter { !ids.contains($0) }
        }
        return ids
    }

    func contacts() async -> [UserItem] {
        guard let client, let list = try? await client.getContacts() else { return [] }
        var result: [UserItem] = []
        for id in list.userIds {
            if users[id] == nil, let u = try? await client.getUser(userId: id) { users[id] = TDConvert.user(u) }
            if let u = users[id] { result.append(u) }
        }
        return result.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    func privateChat(with userId: Int64) async -> Int64? {
        guard let client, let chat = try? await client.createPrivateChat(force: false, userId: userId) else { return nil }
        return chat.id
    }

    // MARK: - Sessions

    func activeSessions() async -> [SessionItem] {
        guard let client, let list = try? await client.getActiveSessions() else { return [] }
        return list.sessions.map { s in
            SessionItem(id: s.id.rawValue, title: "\(s.applicationName) \(s.applicationVersion)",
                        device: [s.deviceModel, s.platform, s.systemVersion].filter { !$0.isEmpty }.joined(separator: ", "),
                        location: [s.ipAddress, s.location].filter { !$0.isEmpty }.joined(separator: " · "),
                        lastActive: s.lastActiveDate, isCurrent: s.isCurrent, isOfficial: s.isOfficialApplication)
        }
    }

    func terminateSession(_ id: Int64) async throws {
        guard let client else { return }
        try await client.terminateSession(sessionId: TdInt64(id))
    }

    // MARK: - Links

    /// t.me / tg:// links → chat id (public chats, message links, invite links of joined chats).
    func resolveInternalLink(_ link: String) async -> Int64? {
        guard let client, let type = try? await client.getInternalLinkType(link: link) else { return nil }
        switch type {
        case .internalLinkTypePublicChat(let p):
            return await resolveUsername(p.chatUsername)
        case .internalLinkTypeMessage(let m):
            guard let info = try? await client.getMessageLinkInfo(url: m.url), info.chatId != 0 else { return nil }
            return info.chatId
        case .internalLinkTypeChatInvite(let i):
            guard let info = try? await client.checkChatInviteLink(inviteLink: i.inviteLink), info.chatId != 0 else { return nil }
            return info.chatId
        default:
            return nil
        }
    }

    func resolveUsername(_ username: String) async -> Int64? {
        guard let client, let chat = try? await client.searchPublicChat(username: username) else { return nil }
        return chat.id
    }

    func joinChat(_ chatId: Int64) async throws {
        guard let client else { return }
        _ = try await client.joinChat(chatId: chatId)
    }

    // MARK: - Profiles

    func userFullInfo(_ userId: Int64) async -> UserProfileInfo? {
        guard let client, let info = try? await client.getUserFullInfo(userId: userId) else { return nil }
        return UserProfileInfo(bio: info.bio?.text ?? "", commonGroupsCount: info.groupInCommonCount, canBeCalled: info.canBeCalled)
    }

    func groupInfo(chatId: Int64) async -> GroupInfo? {
        guard let client, let chat = chats[chatId] else { return nil }
        switch chat.kind {
        case .basicGroup(let id):
            guard let info = try? await client.getBasicGroupFullInfo(basicGroupId: id) else { return nil }
            return GroupInfo(memberCount: basicGroupMembers[id] ?? info.members.count, description: info.description,
                             username: nil, isChannel: false, inviteLink: info.inviteLink?.inviteLink)
        case .supergroup(let id), .channel(let id):
            guard let info = try? await client.getSupergroupFullInfo(supergroupId: id) else { return nil }
            let lite = supergroups[id]
            return GroupInfo(memberCount: info.memberCount, description: info.description, username: lite?.username,
                             isChannel: lite?.isChannel ?? chat.kind.isChannel, inviteLink: info.inviteLink?.inviteLink)
        default:
            return nil
        }
    }

    func loadUser(_ userId: Int64) async {
        guard users[userId] == nil, let client, let u = try? await client.getUser(userId: userId) else { return }
        users[userId] = TDConvert.user(u)
    }

    // MARK: - Files

    private func startDownload(fileId: Int, priority: Int) {
        guard let client else { return }
        Task {
            if let f = try? await client.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: priority, synchronous: false) {
                files.update(id: f.id, localPath: f.local.path, completed: f.local.isDownloadingCompleted,
                             downloaded: f.local.downloadedSize, size: f.size, isActive: f.local.isDownloadingActive)
            }
        }
    }

    func storageUsage() async -> (files: Int64, database: Int64)? {
        guard let client, let s = try? await client.getStorageStatisticsFast() else { return nil }
        return (s.filesSize, s.databaseSize)
    }

    func clearCache() async {
        _ = try? await client?.optimizeStorage(chatIds: nil, chatLimit: nil, count: 0, excludeChatIds: nil, fileTypes: nil,
                                               immunityDelay: 0, returnDeletedFileStatistics: false, size: 0, ttl: 0)
        files.reset()
    }

    /// Human-readable text for TDLib errors ("PHONE_CODE_INVALID" → localized when known).
    nonisolated static func describe(_ error: Swift.Error) -> String {
        if let e = error as? TDLibKit.Error {
            let key = "TDError_" + e.message
            let localized = NSLocalizedString(key, comment: "")
            return localized == key ? e.message : localized
        }
        return error.localizedDescription
    }

    // MARK: - Sponsored messages (AyuConfig.disableAds)

    func reportSecretScreenshot(chatId: Int64) async {
        guard case .secret = chats[chatId]?.kind, activeChatId == chatId,
              AppLock.shared.canShowContent, let client,
              let ids = displayedMessageIds[chatId], !ids.isEmpty else { return }
        // TDLib 1.8.67 reports captures through the screenshot view source.
        do { try await client.viewMessages(chatId: chatId, forceRead: false, messageIds: Array(ids), source: .messageSourceScreenshot) }
        catch { AppLog.debug("Secret screenshot notification: \(error)") }
    }

    func setMessageDisplayed(chatId: Int64, messageId: Int64, displayed: Bool) {
        guard messageId > 0 else { return }
        if displayed { displayedMessageIds[chatId, default: []].insert(messageId) }
        else { displayedMessageIds[chatId]?.remove(messageId) }
    }

    func sponsoredMessage(chatId: Int64) async -> (title: String, text: String, url: String)? {
        guard !config.disableAds, let client, let list = try? await client.getChatSponsoredMessages(chatId: chatId),
              let first = list.messages.first else { return nil }
        let text = TDConvert.body(first.content, sender: .chat(chatId), names: nameOf).plainText
        return (first.title, text, first.sponsor.url)
    }
}
