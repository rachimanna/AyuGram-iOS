import XCTest
@testable import AyuGram

final class StoryItemTests: XCTestCase {
    func testStoryIdentityIncludesPosterAndFirstUnreadSelection() {
        let first = StoryReference(chatId: 1, storyId: 5)
        let second = StoryReference(chatId: 2, storyId: 5)
        XCTAssertNotEqual(first.id, second.id)
        var group = ChatStoryGroup(id: 1, order: 10,
                                  references: [first, StoryReference(chatId: 1, storyId: 8)], maxReadStoryId: 5)
        XCTAssertTrue(group.hasUnread)
        XCTAssertEqual(group.firstUnreadIndex, 1)
        group.maxReadStoryId = 8
        XCTAssertFalse(group.hasUnread)
        XCTAssertEqual(group.firstUnreadIndex, 0)
    }
}
