import XCTest
@testable import AyuGram

final class AppearanceSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "appearance-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCorruptPreferencesHaveSafeFallbacks() {
        defaults.set(-1, forKey: "accentIndex")
        defaults.set(1000.0, forKey: "messageTextSize")
        defaults.set("unknown", forKey: "themeMode")
        defaults.set("unknown", forKey: "premiumPalette")
        let settings = AppearanceSettings(defaults: defaults)
        _ = settings.accent // Previously trapped on a negative array index.
        XCTAssertEqual(settings.themeMode, .system)
        XCTAssertEqual(settings.messageTextSize, 24)
        XCTAssertEqual(settings.premiumPalette, .aurora)
        for value in [Int.min, -1, Theme.accents.count, Int.max] {
            settings.accentIndex = value
            _ = settings.accent
            XCTAssertEqual(AppearanceSettings.validAccentIndex(value), 0)
        }
        XCTAssertEqual(AppearanceSettings.validTextSize(.nan), 16)
        XCTAssertEqual(AppearanceSettings.validTextSize(.infinity), 16)
        XCTAssertEqual(AppearanceSettings.validTextSize(-1), 12)
    }

    func testPremiumAppearanceAndToggleSurviveRelaunch() {
        let settings = AppearanceSettings(defaults: defaults)
        settings.premiumPalette = .ocean
        settings.premiumChatStyle = false
        settings.accentIndex = 2
        let config = AyuConfig(defaults: defaults)
        config.localPremium = true
        let restored = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(restored.premiumPalette, .ocean)
        XCTAssertFalse(restored.premiumChatStyle)
        XCTAssertEqual(restored.accentIndex, 2)
        XCTAssertTrue(AyuConfig(defaults: defaults).localPremium)
        config.localPremium = false
        XCTAssertFalse(AyuConfig(defaults: defaults).localPremium)
        // Turning off cosmetics keeps the chosen palette for the next activation.
        XCTAssertEqual(AppearanceSettings(defaults: defaults).premiumPalette, .ocean)
    }

    func testAvatarPaletteHandlesTheWholeInt64Range() {
        for id in [Int64.min, -7, -1, 0, 1, 7, Int64.max] {
            XCTAssertTrue(Theme.avatarColors.indices.contains(Theme.avatarIndex(for: id)))
            _ = Theme.avatarGradient(for: id)
            _ = Theme.nameColor(for: id)
        }
        XCTAssertEqual(Theme.avatarIndex(for: -42), Theme.avatarIndex(for: 42))
    }
}

final class ComposerFailureTests: XCTestCase {
    @MainActor
    func testFailedSendPreservesExactDraftAndReply() async {
        // Unit-test host has no authenticated Telegram account; no request should be issued.
        XCTAssertNotEqual(TelegramService.shared.authStep, .ready)
        let model = ChatViewModel(chatId: 777)
        let reply = MessageItem(id: 5, chatId: 777, sender: .user(7), isOutgoing: false,
                                date: 0, editDate: 0, body: .text(RichText(text: "hello")))
        model.startReply(reply)
        model.composerText = "  мой черновик\n"
        await model.send()
        XCTAssertEqual(model.composerText, "  мой черновик\n")
        XCTAssertEqual(model.mode, .reply(reply))
        XCTAssertNotNil(model.errorText)
        XCTAssertFalse(model.isSending)
    }

    @MainActor
    func testEditWithoutAuthenticationThrows() async {
        XCTAssertNotEqual(TelegramService.shared.authStep, .ready)
        do {
            try await TelegramService.shared.editText(chatId: 777, messageId: 5, text: RichText(text: "changed"))
            XCTFail("Editing without an authenticated client must not report success")
        } catch {
            XCTAssertTrue(error is TelegramServiceError)
        }
    }
}
