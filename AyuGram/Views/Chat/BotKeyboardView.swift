import SwiftUI
import UIKit

struct BotInlineKeyboardView: View {
    let message: MessageItem
    @Environment(TelegramService.self) private var service
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var busy = false
    @State private var notice: String?
    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array((message.inlineKeyboard ?? []).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, button in
                        Button(button.text) { Task { await activate(button) } }
                            .font(.subheadline).frame(maxWidth: .infinity, minHeight: 36)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            .disabled(busy || !button.enabled || message.ayuDeleted)
                    }
                }
            }
        }
        .alert(L("AppName"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func activate(_ button: BotButtonItem) async {
        guard !busy, !message.ayuDeleted, AppLock.shared.canShowContent else { return }
        busy = true
        defer { busy = false }
        switch button.action {
        case .url(let value): if let url = URL(string: value) { openURL(url) }
        case .copy(let value): UIPasteboard.general.string = value
        case .user(let id): if let chatId = await service.privateChat(with: id) { router.chatPath.append(.chat(chatId)) }
        case .callback(let data):
            do {
                let answer = try await service.botCallback(chatId: message.chatId, messageId: message.id, data: data)
                guard AppLock.shared.canShowContent else { return }
                if !answer.text.isEmpty { notice = answer.text }
                if let url = URL(string: answer.url), !answer.url.isEmpty { openURL(url) }
            } catch { notice = TelegramService.describe(error) }
        case .text, .unsupported: break
        }
    }
}

struct BotReplyKeyboardView: View {
    let model: ChatViewModel
    let keyboard: BotReplyKeyboard
    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(keyboard.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, button in
                        Button(button.text) { Task { await model.sendBotText(button.text, keyboard: keyboard) } }
                            .font(.subheadline).frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            .disabled(!button.enabled || model.isSending)
                    }
                }
            }
        }.padding(8)
    }
}
