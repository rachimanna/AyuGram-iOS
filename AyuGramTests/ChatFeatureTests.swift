import XCTest
@testable import AyuGram

final class ChatFeatureTests: XCTestCase {
    func testExplicitScheduleOverridesAyuDelayWithoutChangingTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let delivery = MessageDelivery(silent: true, scheduledDate: Date(timeIntervalSince1970: 86_400))
        XCTAssertEqual(delivery.sendDate(now: now, ayuScheduled: true), 86_400)
        XCTAssertEqual(delivery.sendDate(now: now, ayuScheduled: false), 86_400)
        XCTAssertEqual(MessageDelivery().sendDate(now: now, ayuScheduled: true), 1_012)
        XCTAssertNil(MessageDelivery().sendDate(now: now, ayuScheduled: false))
    }

    func testLegacySavedPollStillDecodesAndDoesNotAssumeMultipleAnswers() throws {
        let old = Data(#"{"question":"Q","options":[{"text":"A","votePercentage":50,"isChosen":true},{"text":"B","votePercentage":50,"isChosen":false}],"totalVoters":2,"isQuiz":false,"isClosed":false}"#.utf8)
        let poll = try JSONDecoder().decode(PollItem.self, from: old)
        XCTAssertEqual(poll.question, "Q")
        XCTAssertNil(poll.allowsMultipleAnswers)
        XCTAssertNil(poll.pollId)
        XCTAssertTrue(poll.options[0].isChosen)
    }

    func testQuizCorrectAnswerStaysInsideValidOptions() {
        var draft = PollDraft(question: " Which? ", options: [" A ", " B "], quiz: true, correctOption: 1)
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.cleanedOptions, ["A", "B"])
        draft.correctOption = 2
        XCTAssertFalse(draft.isValid)
        draft.correctOption = 0
        draft.options[1] = " \n"
        XCTAssertFalse(draft.isValid)
        draft.options = ["A", String(repeating: "😀", count: 51)]
        XCTAssertFalse(draft.isValid)
    }
}
