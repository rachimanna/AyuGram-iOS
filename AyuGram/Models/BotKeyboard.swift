import Foundation

struct BotButtonItem: Codable, Hashable {
    enum Action: Codable, Hashable {
        case url(String), callback(Data), copy(String), user(Int64), text, unsupported
    }
    var text: String
    var action: Action
    var enabled: Bool { action != .unsupported }
}

struct BotReplyKeyboard {
    var messageId: Int64
    var rows: [[BotButtonItem]]
    var oneTime: Bool
    var forceReply: Bool
}

struct BotCallbackResult {
    var text: String
    var url: String
}
