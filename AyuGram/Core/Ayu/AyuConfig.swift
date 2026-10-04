/*
 * AyuGram for iOS — port of AyuGram4A (https://github.com/AyuGram/AyuGram4A).
 * Original AyuConfig.java: Copyright @Radolyn, 2023. Licensed under GPL-2.0.
 *
 * Same preference keys and defaults as Android (SharedPreferences "ayuconfig"),
 * stored in UserDefaults(suiteName: "ayuconfig").
 */

import Foundation
import Observation

@Observable
final class AyuConfig {
    static let shared = AyuConfig()

    @ObservationIgnored let defaults: UserDefaults

    // MARK: ~ Ghost essentials
    var sendReadPackets: Bool { didSet { put("sendReadPackets", sendReadPackets) } }
    var sendOnlinePackets: Bool { didSet { put("sendOnlinePackets", sendOnlinePackets) } }
    var sendUploadProgress: Bool { didSet { put("sendUploadProgress", sendUploadProgress) } }
    var sendOfflinePacketAfterOnline: Bool { didSet { put("sendOfflinePacketAfterOnline", sendOfflinePacketAfterOnline) } }
    var markReadAfterSend: Bool { didSet { put("markReadAfterSend", markReadAfterSend) } }
    var useScheduledMessages: Bool { didSet { put("useScheduledMessages", useScheduledMessages) } }

    // MARK: ~ Message edits & deletion history
    var saveDeletedMessages: Bool { didSet { put("saveDeletedMessages", saveDeletedMessages) } }
    var saveMessagesHistory: Bool { didSet { put("saveMessagesHistory", saveMessagesHistory) } }

    // MARK: ~ Message saving preferences
    var saveMedia: Bool { didSet { put("saveMedia", saveMedia) } }
    var saveMediaInPrivateChats: Bool { didSet { put("saveMediaInPrivateChats", saveMediaInPrivateChats) } }
    var saveMediaInPublicChannels: Bool { didSet { put("saveMediaInPublicChannels", saveMediaInPublicChannels) } }
    var saveMediaInPrivateChannels: Bool { didSet { put("saveMediaInPrivateChannels", saveMediaInPrivateChannels) } }
    var saveMediaInPublicGroups: Bool { didSet { put("saveMediaInPublicGroups", saveMediaInPublicGroups) } }
    var saveMediaInPrivateGroups: Bool { didSet { put("saveMediaInPrivateGroups", saveMediaInPrivateGroups) } }
    var saveForBots: Bool { didSet { put("saveForBots", saveForBots) } }
    var saveFormatting: Bool { didSet { put("saveFormatting", saveFormatting) } }
    var saveReactions: Bool { didSet { put("saveReactions", saveReactions) } }

    // MARK: ~ Useful features
    /// Android: foreground "AyuGram Push Service". iOS: periodic background refresh (see BackgroundRefresh).
    var keepAliveService: Bool { didSet { put("keepAliveService", keepAliveService) } }
    var disableAds: Bool { didSet { put("disableAds", disableAds) } }
    var localPremium: Bool { didSet { put("localPremium", localPremium) } }
    var regexFiltersEnabled: Bool { didSet { put("regexFiltersEnabled", regexFiltersEnabled); AyuFilter.shared.rebuildCache() } }
    var regexFiltersInChats: Bool { didSet { put("regexFiltersInChats", regexFiltersInChats); AyuFilter.shared.rebuildCache() } }
    var regexFiltersCaseInsensitive: Bool { didSet { put("regexFiltersCaseInsensitive", regexFiltersCaseInsensitive); AyuFilter.shared.rebuildCache() } }
    private(set) var regexFilters: [String]

    // MARK: ~ Customization
    var deletedMarkText: String { didSet { defaults.set(deletedMarkText, forKey: "deletedMarkText") } }
    var editedMarkText: String { didSet { defaults.set(editedMarkText, forKey: "editedMarkText") } }
    /// Android: toggle in the navigation drawer. iOS: ghost button in the chat list toolbar.
    var showGhostToggleInDrawer: Bool { didSet { put("showGhostToggleInDrawer", showGhostToggleInDrawer) } }
    var showKillButtonInDrawer: Bool { didSet { put("showKillButtonInDrawer", showKillButtonInDrawer) } }

    // MARK: ~ AyuSync
    var syncEnabled: Bool { didSet { put("syncEnabled", syncEnabled) } }
    var useSecureConnection: Bool { didSet { put("useSecureConnection", useSecureConnection) } }
    var syncServerURL: String { didSet { defaults.set(syncServerURL, forKey: "syncServerURL") } }
    var syncServerToken: String { didSet { defaults.set(syncServerToken, forKey: "syncServerToken") } }

    // MARK: ~ Debug
    var walMode: Bool { didSet { put("walMode", walMode) } }

    init(defaults: UserDefaults = UserDefaults(suiteName: "ayuconfig") ?? .standard) {
        self.defaults = defaults
        func b(_ key: String, _ def: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? def }

        sendReadPackets = b("sendReadPackets", true)
        sendOnlinePackets = b("sendOnlinePackets", true)
        sendUploadProgress = b("sendUploadProgress", true)
        sendOfflinePacketAfterOnline = b("sendOfflinePacketAfterOnline", false)
        markReadAfterSend = b("markReadAfterSend", true)
        useScheduledMessages = b("useScheduledMessages", false)

        saveDeletedMessages = b("saveDeletedMessages", true)
        saveMessagesHistory = b("saveMessagesHistory", true)

        saveMedia = b("saveMedia", true)
        saveMediaInPrivateChats = b("saveMediaInPrivateChats", true)
        saveMediaInPublicChannels = b("saveMediaInPublicChannels", false)
        saveMediaInPrivateChannels = b("saveMediaInPrivateChannels", true)
        saveMediaInPublicGroups = b("saveMediaInPublicGroups", false)
        saveMediaInPrivateGroups = b("saveMediaInPrivateGroups", true)
        saveForBots = b("saveForBots", true)
        saveFormatting = b("saveFormatting", true)
        saveReactions = b("saveReactions", true)

        keepAliveService = b("keepAliveService", true)
        disableAds = b("disableAds", true)
        localPremium = b("localPremium", false)
        regexFiltersEnabled = b("regexFiltersEnabled", false)
        regexFiltersInChats = b("regexFiltersInChats", false)
        regexFiltersCaseInsensitive = b("regexFiltersCaseInsensitive", true)
        regexFilters = AyuConfig.decodeFilters(defaults.string(forKey: "regexFilters"))

        deletedMarkText = defaults.string(forKey: "deletedMarkText") ?? AyuConstants.defaultDeletedMark
        editedMarkText = defaults.string(forKey: "editedMarkText") ?? L("EditedMessage")
        showGhostToggleInDrawer = b("showGhostToggleInDrawer", true)
        showKillButtonInDrawer = b("showKillButtonInDrawer", false)

        syncEnabled = b("syncEnabled", false)
        useSecureConnection = b("useSecureConnection", true)
        syncServerURL = defaults.string(forKey: "syncServerURL") ?? AyuConstants.defaultAyuSyncServer
        syncServerToken = defaults.string(forKey: "syncServerToken") ?? ""

        walMode = b("walMode", true)
    }

    private func put(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
    }

    // MARK: - Ghost mode (same semantics as AyuConfig.isGhostModeActive on Android)

    var isGhostModeActive: Bool {
        !sendReadPackets && !sendOnlinePackets && !sendUploadProgress && sendOfflinePacketAfterOnline
    }

    func setGhostMode(_ enabled: Bool) {
        sendReadPackets = !enabled
        sendOnlinePackets = !enabled
        sendUploadProgress = !enabled
        sendOfflinePacketAfterOnline = enabled
        NotificationCenter.default.post(name: .ayuGhostModeChanged, object: nil)
    }

    func toggleGhostMode() {
        setGhostMode(!isGhostModeActive)
    }

    // MARK: - Saving rules

    /// AyuConfig.saveDeletedMessageFor — `isBot` is nil when the dialog is not a private chat.
    func saveDeletedMessage(isBotDialog: Bool) -> Bool {
        guard saveDeletedMessages else { return false }
        return !isBotDialog || saveForBots
    }

    func saveEditedMessage(isBotDialog: Bool) -> Bool {
        guard saveMessagesHistory else { return false }
        return !isBotDialog || saveForBots
    }

    func saveMedia(for kind: AyuDialogKind) -> Bool {
        guard saveMedia else { return false }
        switch kind {
        case .privateChat: return saveMediaInPrivateChats
        case .publicChannel: return saveMediaInPublicChannels
        case .privateChannel: return saveMediaInPrivateChannels
        case .publicGroup: return saveMediaInPublicGroups
        case .privateGroup: return saveMediaInPrivateGroups
        }
    }

    var sqliteJournalMode: String { walMode ? "WAL" : "DELETE" }

    // MARK: - Regex filters (stored as JSON array, same as Android "regexFilters")

    func addFilter(_ text: String) {
        var list = regexFilters
        list.insert(text, at: 0)
        storeFilters(list)
    }

    func editFilter(at index: Int, _ text: String) {
        guard regexFilters.indices.contains(index) else { return }
        var list = regexFilters
        list[index] = text
        storeFilters(list)
    }

    func removeFilter(at index: Int) {
        guard regexFilters.indices.contains(index) else { return }
        var list = regexFilters
        list.remove(at: index)
        storeFilters(list)
    }

    private func storeFilters(_ list: [String]) {
        regexFilters = list
        if let data = try? JSONEncoder().encode(list), let str = String(data: data, encoding: .utf8) {
            defaults.set(str, forKey: "regexFilters")
        }
        AyuFilter.shared.rebuildCache()
    }

    static func decodeFilters(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }
}

/// Dialog categories used by the per-chat-type "Save media" switches.
enum AyuDialogKind: Equatable {
    case privateChat, publicChannel, privateChannel, publicGroup, privateGroup
}

extension Notification.Name {
    static let ayuGhostModeChanged = Notification.Name("AyuGhostModeChanged")
    static let ayuMessageEdited = Notification.Name("AyuMessageEdited")       // userInfo: chatId, messageId
    static let ayuMessagesDeleted = Notification.Name("AyuMessagesDeleted")   // userInfo: chatId, messageIds
}
