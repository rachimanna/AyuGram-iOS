/*
 * AyuGram for iOS — a native port of AyuGram4A (https://github.com/AyuGram/AyuGram4A).
 * Copyright (C) 2023 Radolyn (AyuGram), exteraGram, Telegram Android authors.
 * iOS port: GPL-2.0, see LICENSE and NOTICE.
 */

import SwiftUI
import UIKit
import UserNotifications

@main
struct AyuGramApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var service = TelegramService.shared
    @State private var appearance = AppearanceSettings.shared
    @State private var router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(service)
                .environment(appearance)
                .environment(router)
                .environment(AyuConfig.shared)
                .tint(appearance.accent)
                .preferredColorScheme(appearance.colorScheme)
                .task { service.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            service.setAppActive(phase == .active)
            if phase == .background { NotificationService.scheduleBackgroundRefresh() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationService.registerBackgroundTask()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let chatId = response.notification.request.content.userInfo["chatId"] as? Int64 {
            await MainActor.run { AppRouter.shared.openChat(chatId) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [] // the app is in the foreground — the chat list already shows the message
    }
}

/// Navigation state shared between notifications, deep links and the chat list.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var chatPath: [Route] = []
    var selectedTab: Int = 0

    func openChat(_ chatId: Int64) {
        selectedTab = 0
        chatPath = [.chat(chatId)]
    }
}

/// Navigation destinations inside the chats stack.
enum Route: Hashable {
    case chat(Int64)
    case archive
    case profile(chatId: Int64)
    case deletedMessages(chatId: Int64)
}

extension View {
    /// Registers all app routes on a NavigationStack.
    func withAppRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .chat(let id): ChatView(chatId: id)
            case .archive: ArchiveView()
            case .profile(let id): ProfileView(chatId: id)
            case .deletedMessages(let id): DeletedMessagesView(chatId: id)
            }
        }
    }
}
