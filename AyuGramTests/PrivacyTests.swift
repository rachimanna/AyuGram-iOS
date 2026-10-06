import XCTest
@testable import AyuGram

@MainActor
final class PrivacyTests: XCTestCase {
    private func preferences() -> PrivacyPreferences {
        PrivacyPreferences(defaults: UserDefaults(suiteName: "privacy-test-\(UUID().uuidString)")!)
    }
    private func config() -> AyuConfig { AyuConfig(defaults: UserDefaults(suiteName: "config-test-\(UUID().uuidString)")!) }
    func testChatOverridesGlobalGhostAndTypingRemainsIndependent() {
        let preferences = preferences(), config = config(); preferences.selectAccount(100)
        config.setGhostMode(true)
        XCTAssertTrue(preferences.isGhost(1, config: config)); XCTAssertFalse(preferences.sendsRead(1, config: config))
        preferences.update(1) { $0.ghost = .off }
        XCTAssertFalse(preferences.isGhost(1, config: config)); XCTAssertTrue(preferences.sendsRead(1, config: config))
        XCTAssertTrue(preferences.sendsTyping(1, config: config))
        preferences.snapshot.suppressTyping = true
        XCTAssertFalse(preferences.sendsTyping(1, config: config)); XCTAssertTrue(preferences.sendsRead(1, config: config))
        XCTAssertFalse(preferences.sendsRead(2, config: config))
    }
    func testPreferencesDoNotLeakBetweenAccounts() {
        let p = preferences(); p.selectAccount(1); p.update(42) { $0.hidden = true; $0.ghost = .on }; p.snapshot.hideOwnPhone = true
        p.selectAccount(2); XCTAssertFalse(p.chat(42).hidden); XCTAssertEqual(p.chat(42).ghost, .inherit); XCTAssertFalse(p.snapshot.hideOwnPhone)
        p.selectAccount(1); XCTAssertTrue(p.chat(42).hidden); XCTAssertEqual(p.chat(42).ghost, .on); XCTAssertTrue(p.snapshot.hideOwnPhone)
    }
    func testProtectedFolderAppliesOutsideFolderTab() {
        let p = preferences(); p.selectAccount(1); p.snapshot.lockedFolders = [8]
        XCTAssertTrue(p.isProtected(100, positions: [.main: .init(order: 1, isPinned: false), .folder(8): .init(order: 1, isPinned: false)]))
        XCTAssertFalse(p.isProtected(101, positions: [.folder(9): .init(order: 1, isPinned: false)]))
    }
    func testDiffReconstructsBothVersionsIncludingEmoji() {
        for (old, new) in [("Привет 👨‍👩‍👧!", "Привет 👨‍👩‍👧, мир!"), ("abc", "axc"), ("", "added"), ("gone", ""), ("aaaa", "aa"), ("abc", "cab")] {
            let runs = TextDiff.runs(old: old, new: new)
            XCTAssertEqual(runs.filter { $0.kind != .inserted }.map(\.text).joined(), old)
            XCTAssertEqual(runs.filter { $0.kind != .removed }.map(\.text).joined(), new)
        }
    }
    func testPINIsSaltedAndRejectsWrongCode() throws {
        let a = try PINRecord.make("123456"), b = try PINRecord.make("123456")
        XCTAssertNotEqual(a.salt, b.salt); XCTAssertNotEqual(a.digest, b.digest)
        XCTAssertTrue(a.matches("123456")); XCTAssertFalse(a.matches("123457"))
        XCTAssertThrowsError(try PINRecord.make("abc")); XCTAssertThrowsError(try PINRecord.make("12"))
        let roundTrip = try JSONDecoder().decode(PINRecord.self, from: JSONEncoder().encode(a)); XCTAssertTrue(roundTrip.matches("123456"))
    }
    func testDatabaseUpgradePreservesDeletedMediaAndSeparatesAccounts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try AyuDatabase(path: url.path, journalMode: "DELETE")
        let message = MessageItem(id: 1, chatId: 42, sender: .user(2), isOutgoing: false, date: 0, editDate: 0, body: .text(RichText(text: "kept")))
        _ = db.insertDeleted(userId: 100, message: message, entityCreateDate: 1, mediaPath: nil, reactions: [])
        try db.db.execute("DROP TABLE retainedmedia; PRAGMA user_version=1;")
        let upgraded = try AyuDatabase(path: url.path, journalMode: "DELETE")
        XCTAssertEqual(upgraded.allDeleted(userId: 100, limit: 100, offset: 0).first?.body.plainText, "kept")
        XCTAssertTrue(upgraded.allDeleted(userId: 101, limit: 100, offset: 0).isEmpty)
        XCTAssertEqual(try upgraded.db.scalarInt("PRAGMA user_version"), 2)
    }
}
