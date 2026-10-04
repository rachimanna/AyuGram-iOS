import XCTest
@testable import AyuGram

final class AyuFilterTests: XCTestCase {
    private func makeConfig(_ filters: [String], caseInsensitive: Bool = true, enabled: Bool = true) -> AyuConfig {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let config = AyuConfig(defaults: defaults)
        config.regexFiltersCaseInsensitive = caseInsensitive
        config.regexFiltersEnabled = enabled
        for f in filters.reversed() { config.addFilter(f) } // addFilter inserts at index 0, like Android
        return config
    }

    func testFiltersAreStoredLikeAndroid() {
        let config = makeConfig(["first", "second"])
        XCTAssertEqual(config.regexFilters, ["first", "second"])
        XCTAssertEqual(config.defaults.string(forKey: "regexFilters"), #"["first","second"]"#)
        config.editFilter(at: 1, "changed")
        config.removeFilter(at: 0)
        XCTAssertEqual(config.regexFilters, ["changed"])
        XCTAssertEqual(AyuConfig.decodeFilters(config.defaults.string(forKey: "regexFilters")), ["changed"])
    }

    func testCaseInsensitiveMatching() {
        let filter = AyuFilter(config: makeConfig(["#реклама", "^promo"]))
        XCTAssertTrue(filter.isFiltered(text: "Привет #РЕКЛАМА", dialogId: 1, messageId: 1))
        XCTAssertFalse(filter.isFiltered(text: "обычный текст", dialogId: 1, messageId: 2))
        // MULTILINE: ^ matches at the start of every line (Pattern.MULTILINE)
        XCTAssertTrue(filter.isFiltered(text: "hello\nPROMO code", dialogId: 1, messageId: 3))
    }

    func testCaseSensitiveMatching() {
        let filter = AyuFilter(config: makeConfig(["Ads"], caseInsensitive: false))
        XCTAssertFalse(filter.isFiltered(text: "ads here", dialogId: 1, messageId: 1))
        XCTAssertTrue(filter.isFiltered(text: "Ads here", dialogId: 1, messageId: 2))
    }

    func testDisabledFiltersNeverMatch() {
        let filter = AyuFilter(config: makeConfig(["x"], enabled: false))
        XCTAssertFalse(filter.isFiltered(text: "x", dialogId: 1, messageId: 1))
    }

    func testInvalidPatternIsSkipped() {
        let filter = AyuFilter(config: makeConfig(["(unclosed", "valid"]))
        XCTAssertTrue(filter.isFiltered(text: "valid", dialogId: 1, messageId: 1))
        XCTAssertFalse(filter.isFiltered(text: "(unclosed", dialogId: 1, messageId: 2))
        XCTAssertNotNil(AyuFilter.validate("(unclosed"))
        XCTAssertNil(AyuFilter.validate("valid"))
    }

    func testAlbumSharesVerdictAndCacheCanBeInvalidated() {
        let config = makeConfig(["spam"])
        let filter = AyuFilter(config: config)
        XCTAssertTrue(filter.isFiltered(text: "spam", dialogId: 5, messageId: 10, groupMessageIds: [11, 12]))
        // Other album items are answered from the cache even without text.
        XCTAssertTrue(filter.isFiltered(text: nil, dialogId: 5, messageId: 11))
        filter.invalidate(dialogId: 5, messageId: 11)
        XCTAssertFalse(filter.isFiltered(text: nil, dialogId: 5, messageId: 11))
    }

    func testAppliesInChannelsOnlyUnlessEnabledForChats() {
        let config = makeConfig(["x"])
        let filter = AyuFilter(config: config)
        XCTAssertTrue(filter.appliesIn(isChannel: true))
        XCTAssertFalse(filter.appliesIn(isChannel: false))
        config.regexFiltersInChats = true
        XCTAssertTrue(filter.appliesIn(isChannel: false))
    }
}

final class AyuConfigTests: XCTestCase {
    private func fresh() -> AyuConfig {
        AyuConfig(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }

    func testDefaultsMatchAndroid() {
        let c = fresh()
        XCTAssertTrue(c.sendReadPackets)
        XCTAssertTrue(c.sendOnlinePackets)
        XCTAssertTrue(c.sendUploadProgress)
        XCTAssertFalse(c.sendOfflinePacketAfterOnline)
        XCTAssertTrue(c.saveDeletedMessages)
        XCTAssertTrue(c.saveMessagesHistory)
        XCTAssertFalse(c.saveMediaInPublicChannels)
        XCTAssertTrue(c.saveMediaInPrivateChats)
        XCTAssertEqual(c.deletedMarkText, "🧹")
        XCTAssertFalse(c.isGhostModeActive)
    }

    func testGhostModeToggle() {
        let c = fresh()
        c.setGhostMode(true)
        XCTAssertTrue(c.isGhostModeActive)
        XCTAssertFalse(c.sendReadPackets)
        XCTAssertFalse(c.sendOnlinePackets)
        XCTAssertFalse(c.sendUploadProgress)
        XCTAssertTrue(c.sendOfflinePacketAfterOnline)
        // persisted under the Android keys
        XCTAssertEqual(c.defaults.object(forKey: "sendReadPackets") as? Bool, false)
        c.toggleGhostMode()
        XCTAssertFalse(c.isGhostModeActive)
        XCTAssertTrue(c.sendReadPackets)
    }

    func testSavingRulesForBots() {
        let c = fresh()
        XCTAssertTrue(c.saveDeletedMessage(isBotDialog: true))
        c.saveForBots = false
        XCTAssertFalse(c.saveDeletedMessage(isBotDialog: true))
        XCTAssertTrue(c.saveDeletedMessage(isBotDialog: false))
        c.saveDeletedMessages = false
        XCTAssertFalse(c.saveDeletedMessage(isBotDialog: false))
    }

    func testMediaSavingPerDialogKind() {
        let c = fresh()
        XCTAssertTrue(c.saveMedia(for: .privateChat))
        XCTAssertFalse(c.saveMedia(for: .publicChannel))
        XCTAssertTrue(c.saveMedia(for: .privateChannel))
        c.saveMedia = false
        XCTAssertFalse(c.saveMedia(for: .privateChat))
    }

    func testLocalReadStore() {
        let store = LocalReadStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        XCTAssertEqual(store.readUntil(chatId: 7), 0)
        store.markRead(chatId: 7, until: 100)
        store.markRead(chatId: 7, until: 50) // never goes backwards
        XCTAssertEqual(store.readUntil(chatId: 7), 100)
        var chat = ChatItem(id: 7, title: "t", kind: .user(userId: 7))
        chat.unreadCount = 3
        chat.lastMessage = MessageItem(id: 100, chatId: 7, sender: .user(7), isOutgoing: false, date: 0, editDate: 0, body: .text(RichText(text: "x")))
        XCTAssertEqual(chat.visibleUnreadCount(localReadUntil: store.readUntil(chatId: 7)), 0)
        XCTAssertEqual(chat.visibleUnreadCount(localReadUntil: 99), 3)
    }

    func testAyuStateDeletePermission() {
        let state = AyuState()
        state.permitDeleteMessages(chatId: 1, messageIds: [5])
        XCTAssertTrue(state.isDeletePermitted(chatId: 1, messageId: 5))
        state.messageDeleted(chatId: 1, messageId: 5)
        XCTAssertFalse(state.isDeletePermitted(chatId: 1, messageId: 5))
        state.permitDeleteWholeChat(chatId: 2)
        XCTAssertTrue(state.isDeletePermitted(chatId: 2, messageId: 999))
    }
}
