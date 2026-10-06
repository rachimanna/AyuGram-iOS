/*
 * iOS replacement for AyuGram's "AyuGram Push Service" (keepAliveService) on Android.
 *
 * Android keeps a foreground service with a live MTProto connection. iOS does not allow
 * long-running background connections for non-VoIP apps, and Telegram's push gateway only
 * delivers APNs pushes to apps whose APNs key Telegram holds (i.e. official apps).
 * Closest possible behaviour:
 *   • while the app is alive in the background (a few seconds to minutes after leaving it, or
 *     during a background refresh), incoming messages produce local notifications;
 *   • BGAppRefreshTask wakes the app periodically (iOS decides how often) to sync with TDLib.
 */

import BackgroundTasks
import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func onNewMessage(_ message: MessageItem, chat: ChatItem?, appActive: Bool, title: String) {
        guard !appActive, authorized, !message.isOutgoing, !message.body.isService,
              let chat, !chat.isMuted, !message.ayuDeleted else { return }
        // Don't show notifications for messages hidden by the regex filters.
        if AyuFilter.shared.appliesIn(isChannel: chat.kind.isChannel),
           AyuFilter.shared.isFiltered(text: message.body.plainText, dialogId: message.chatId, messageId: message.id) {
            return
        }
        guard !AppLock.shared.decoy else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        let preview = MessagePreview.text(for: message.body)
        if chat.kind.isGroup {
            content.subtitle = TelegramService.shared.nameOf(message.sender)
        }
        if AppLock.shared.enabled || PrivacyPreferences.shared.isProtected(chat.id, positions: chat.positions) {
            content.title = "AyuGram"; content.subtitle = ""; content.body = L("PrivateNotification")
        } else { content.body = preview }
        content.sound = .default
        content.threadIdentifier = "\(message.chatId)"
        content.userInfo = ["chatId": message.chatId]
        let request = UNNotificationRequest(identifier: "\(message.chatId)_\(message.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func onHistoryChange(chatId: Int64, edited: Bool) {
        guard authorized, !AppLock.shared.decoy,
              edited ? PrivacyPreferences.shared.snapshot.notifyEdits : PrivacyPreferences.shared.snapshot.notifyDeletions,
              let chat = TelegramService.shared.chats[chatId], !chat.isMuted else { return }
        let content = UNMutableNotificationContent()
        let privateContent = AppLock.shared.enabled || PrivacyPreferences.shared.isProtected(chatId, positions: chat.positions)
        content.title = privateContent ? "AyuGram" : chat.title
        content.body = privateContent ? L("PrivateNotification") : L(edited ? "MessageEditedNotice" : "MessageDeletedNotice")
        content.sound = .default; content.userInfo = ["chatId": chatId, "historyChange": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "history-\(chatId)-\(edited)-\(UUID().uuidString)", content: content, trigger: nil))
    }

    // MARK: - Background refresh

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AyuConstants.backgroundRefreshTaskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return task.setTaskCompleted(success: false) }
            Task { @MainActor in
                NotificationService.scheduleBackgroundRefresh()
                // TDLib is already running inside the process; give it time to receive updates.
                TelegramService.shared.start()
                let completion = TaskCompletion(task)
                let work = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    completion.finish(success: true)
                }
                task.expirationHandler = {
                    work.cancel()
                    Task { @MainActor in completion.finish(success: false) }
                }
            }
        }
    }

    static func scheduleBackgroundRefresh() {
        guard AyuConfig.shared.keepAliveService else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AyuConstants.backgroundRefreshTaskId)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: AyuConstants.backgroundRefreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.debug("BG refresh not scheduled: \(error)")
        }
    }
}

/// Makes sure a BGTask is completed exactly once.
@MainActor
private final class TaskCompletion {
    private let task: BGTask
    private var done = false

    init(_ task: BGTask) { self.task = task }

    func finish(success: Bool) {
        guard !done else { return }
        done = true
        task.setTaskCompleted(success: success)
    }
}
