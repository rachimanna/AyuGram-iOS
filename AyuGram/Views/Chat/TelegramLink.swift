import SwiftUI
import UIKit

/// Telegram links opened from message text.
enum TelegramLink {
    case username(String)
    case internalLink(String)

    static func parse(_ url: URL) -> TelegramLink? {
        if url.scheme == "tg" { return .internalLink(url.absoluteString) }
        guard let host = url.host?.lowercased(), ["t.me", "telegram.me", "telegram.dog"].contains(host) else { return nil }
        return .internalLink(url.absoluteString)
    }

    /// Returns the chat to open; if nothing can be resolved in-app the link is opened in the browser.
    @MainActor
    static func resolve(_ link: TelegramLink) async -> Int64? {
        let service = TelegramService.shared
        switch link {
        case .username(let name):
            return await service.resolveUsername(name)
        case .internalLink(let s):
            if let id = await service.resolveInternalLink(s) { return id }
            if let url = URL(string: s) { _ = await UIApplication.shared.open(url) }
            return nil
        }
    }
}
