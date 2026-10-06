import Foundation

/// Per-message options; explicit scheduling takes precedence over AyuGram's 12-second mode.
struct MessageDelivery: Equatable {
    var silent = false
    var scheduledDate: Date?

    func sendDate(now: Date, ayuScheduled: Bool) -> Int? {
        if let scheduledDate { return Int(scheduledDate.timeIntervalSince1970) }
        return ayuScheduled ? Int(now.timeIntervalSince1970) + 12 : nil
    }
}

struct PollDraft {
    var question = ""
    var options = ["", ""]
    var anonymous = true
    var multipleAnswers = false
    var quiz = false
    var correctOption = 0

    var cleanedQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanedOptions: [String] { options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    var isValid: Bool {
        !cleanedQuestion.isEmpty && cleanedQuestion.utf16.count <= 255 && (2...10).contains(options.count)
        && cleanedOptions.allSatisfy { !$0.isEmpty && $0.utf16.count <= 100 }
        && (!quiz || options.indices.contains(correctOption))
    }
}

struct MessageSearchPage {
    var messages: [MessageItem]
    var nextMessageId: Int64 = 0
    var nextSecretOffset: String = ""
    var hasMore: Bool = false
}
