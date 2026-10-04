import XCTest
@testable import AyuGram

final class AyuDatabaseTests: XCTestCase {
    private var path: String!
    private var db: AyuDatabase!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "ayu-test-\(UUID().uuidString).sqlite"
        db = try AyuDatabase(path: path, journalMode: "WAL")
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    private func message(_ id: Int64, chat: Int64 = -100, text: String = "hello", album: Int64 = 0) -> MessageItem {
        var m = MessageItem(id: id, chatId: chat, sender: .user(42), isOutgoing: false, date: 1_700_000_000, editDate: 0,
                            body: .text(RichText(text: text, entities: [TextEntityItem(offset: 0, length: 2, kind: .bold)])))
        m.mediaAlbumId = album
        return m
    }

    func testCacheRoundTrip() {
        db.cache([message(1 << 20), message(2 << 20, text: "second")], userId: 1)
        let m = db.cachedMessage(userId: 1, dialogId: -100, messageId: 2 << 20)
        XCTAssertEqual(m?.body.plainText, "second")
        XCTAssertEqual(m?.body.richText?.entities.first?.kind, .bold)
        XCTAssertNil(db.cachedMessage(userId: 2, dialogId: -100, messageId: 2 << 20), "per-account isolation")
        db.removeCached(userId: 1, dialogId: -100, messageIds: [2 << 20])
        XCTAssertNil(db.cachedMessage(userId: 1, dialogId: -100, messageId: 2 << 20))
        XCTAssertEqual(db.stats().cached, 1)
    }

    func testDeletedMessagesAreUniqueAndKeepReactions() {
        let reactions = [ReactionItem(emoji: "👍", customEmojiId: nil, count: 3, isChosen: true),
                         ReactionItem(emoji: nil, customEmojiId: 777, count: 1, isChosen: false)]
        let first = db.insertDeleted(userId: 1, message: message(10 << 20), entityCreateDate: 1, mediaPath: nil, reactions: reactions)
        XCTAssertNotNil(first)
        let second = db.insertDeleted(userId: 1, message: message(10 << 20), entityCreateDate: 2, mediaPath: nil, reactions: [])
        XCTAssertNil(second, "INSERT OR IGNORE on (userId, dialogId, topicId, messageId)")
        XCTAssertTrue(db.deletedExists(userId: 1, dialogId: -100, topicId: 0, messageId: 10 << 20))

        let stored = db.deletedMessage(userId: 1, dialogId: -100, messageId: 10 << 20)
        XCTAssertEqual(stored?.ayuDeleted, true)
        XCTAssertEqual(stored?.reactions.count, 2)
        XCTAssertEqual(stored?.reactions.first(where: { $0.customEmojiId == 777 })?.count, 1)
    }

    func testDeletedRangeQueryAndRemoval() {
        for i in 1...5 { db.insertDeleted(userId: 1, message: message(Int64(i) << 20), entityCreateDate: i, mediaPath: nil, reactions: []) }
        let range = db.deletedMessages(userId: 1, dialogId: -100, startId: 2 << 20, endId: 4 << 20, limit: 50)
        XCTAssertEqual(range.map { $0.id >> 20 }, [2, 3, 4])
        XCTAssertEqual(db.latestDeleted(userId: 1, dialogId: -100, limit: 2).map { $0.id >> 20 }, [5, 4])
        db.removeDeleted(userId: 1, dialogId: -100, messageId: 3 << 20)
        XCTAssertNil(db.deletedMessage(userId: 1, dialogId: -100, messageId: 3 << 20))
        XCTAssertEqual(db.stats().deleted, 4)
    }

    func testMediaPathOverridesFileLocation() {
        var m = message(20 << 20)
        m.body = .photo(PhotoItem(thumb: nil, file: FileRef(id: 9, size: 10, localPath: nil, uniqueId: "u"), width: 1, height: 1),
                        caption: RichText(text: "cap"))
        db.insertDeleted(userId: 1, message: m, entityCreateDate: 1, mediaPath: "/tmp/Saved Attachments/x.jpg", reactions: [])
        let stored = db.deletedMessage(userId: 1, dialogId: -100, messageId: 20 << 20)
        XCTAssertEqual(stored?.body.mainFile?.localPath, "/tmp/Saved Attachments/x.jpg")
        XCTAssertEqual(stored?.body.ayuDocumentType, AyuConstants.documentTypePhoto)
    }

    func testRevisions() {
        db.insertRevision(userId: 1, message: message(30 << 20, text: "v1"), entityCreateDate: 100, mediaPath: nil)
        db.insertRevision(userId: 1, message: message(30 << 20, text: "v2"), entityCreateDate: 200, mediaPath: nil)
        let revs = db.revisions(userId: 1, dialogId: -100, messageId: 30 << 20)
        XCTAssertEqual(revs.map(\.message.body.plainText), ["v1", "v2"])
        XCTAssertEqual(db.messagesWithRevisions(userId: 1, dialogId: -100, messageIds: [30 << 20, 31 << 20]), [30 << 20])
        db.clean()
        XCTAssertEqual(db.stats().revisions, 0)
    }
}

final class AyuMessagesControllerTests: XCTestCase {
    private var controller: AyuMessagesController!
    private var config: AyuConfig!
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "ayu-ctl-\(UUID().uuidString).sqlite"
        config = AyuConfig(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        controller = AyuMessagesController(config: config, databasePath: path)
        controller.userId = 1
        controller.sync()
    }

    override func tearDown() {
        controller = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    private func msg(_ id: Int64, _ text: String) -> MessageItem {
        MessageItem(id: id << 20, chatId: 5, sender: .user(5), isOutgoing: false, date: 1, editDate: 0, body: .text(RichText(text: text)))
    }

    private let ctx = AyuDialogContext(isBot: false, kind: .privateChat)

    func testEditCreatesRevisionWithPreviousText() {
        controller.onMessagesSeen([msg(1, "original")])
        controller.onMessageContentChanged(chatId: 5, messageId: 1 << 20, newBody: .text(RichText(text: "edited")), context: ctx)
        controller.sync()
        let exp = expectation(description: "revisions")
        controller.revisions(chatId: 5, messageId: 1 << 20) { revs in
            XCTAssertEqual(revs.map(\.message.body.plainText), ["original"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testIdenticalEditIsNotStored() {
        controller.onMessagesSeen([msg(2, "same")])
        controller.onMessageContentChanged(chatId: 5, messageId: 2 << 20, newBody: .text(RichText(text: "same")), context: ctx)
        controller.sync()
        let exp = expectation(description: "revisions")
        controller.revisions(chatId: 5, messageId: 2 << 20) { revs in
            XCTAssertTrue(revs.isEmpty)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testDeletionIsSavedUnlessPermitted() {
        controller.onMessagesSeen([msg(3, "will be deleted"), msg(4, "my own delete")])
        AyuState.shared.permitDeleteMessages(chatId: 5, messageIds: [4 << 20])
        let exp = expectation(description: "deleted")
        controller.onMessagesDeleted(chatId: 5, messageIds: [3 << 20, 4 << 20], context: ctx) { saved in
            XCTAssertEqual(saved.map(\.id), [3 << 20])
            XCTAssertTrue(saved.allSatisfy(\.ayuDeleted))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testDeletionRespectsSaveForBots() {
        config.saveForBots = false
        controller.onMessagesSeen([msg(6, "bot msg")])
        let exp = expectation(description: "deleted")
        controller.onMessagesDeleted(chatId: 5, messageIds: [6 << 20], context: AyuDialogContext(isBot: true, kind: .privateChat)) { saved in
            XCTAssertTrue(saved.isEmpty)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}

final class OpusOggDecoderTests: XCTestCase {
    func testWavHeader() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "t-\(UUID().uuidString).wav")
        try OpusOggDecoder.writeWav(pcm: [0, 1, -1, 100], channels: 1, sampleRate: 48_000, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertThrowsError(try OpusOggDecoder.decode(Data("not an ogg file".utf8)))
    }
}
