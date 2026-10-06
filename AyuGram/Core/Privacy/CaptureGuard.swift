import SwiftUI
import UIKit

/// Uses documented capture notifications. Screenshots can only be reported after capture.
@MainActor @Observable
final class CaptureGuard {
    static let shared = CaptureGuard()
    var screenshotNotice = false
    private var window: UIWindow?
    private var started = false
    private var observers: [NSObjectProtocol] = []
    var secretChatId: Int64? {
        guard PrivacyPreferences.shared.snapshot.shieldSecretCapture else { return nil }
        for route in AppRouter.shared.chatPath.reversed() {
            let id: Int64
            switch route {
            case .chat(let value), .profile(let value), .deletedMessages(let value): id = value
            case .archive: continue
            }
            if case .secret = TelegramService.shared.chats[id]?.kind { return id }
        }
        return nil
    }
    func start() {
        guard !started else { return }; started = true
        observers.append(NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.secretChatId, AppLock.shared.canShowContent else { return }
                self.screenshotNotice = true
                Task { await TelegramService.shared.reportSecretScreenshot(chatId: id) }
            }
        })
        refresh()
    }
    func refresh() {
        let shield = AppLock.shared.curtain || (secretChatId != nil && UIScreen.main.isCaptured)
        guard shield else { window?.isHidden = true; return }
        if window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState != .unattached }) {
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = .alert + 1
            let controller = UIViewController()
            controller.view.backgroundColor = .systemBackground
            let label = UILabel(); label.text = "AyuGram"; label.font = .preferredFont(forTextStyle: .title1); label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor), label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
            cover.rootViewController = controller; window = cover
        }
        window?.isHidden = false
    }
}
