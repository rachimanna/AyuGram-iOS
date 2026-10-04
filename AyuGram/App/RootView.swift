import SwiftUI

struct RootView: View {
    @Environment(TelegramService.self) private var service

    var body: some View {
        Group {
            switch service.authStep {
            case .loading:
                SplashView()
            case .needsApiCredentials:
                ApiCredentialsView()
            case .phone, .code, .qr, .password, .registration, .unsupported:
                AuthFlowView()
            case .ready:
                MainTabView()
                    .onAppear { NotificationService.shared.requestAuthorization() }
            case .loggingOut:
                SplashView(text: L("LoggingOut"))
            }
        }
        .animation(.default, value: service.authStep)
    }
}

struct SplashView: View {
    var text: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            GhostGlyph().frame(width: 72, height: 72)
            Text(AyuConstants.appName).font(.largeTitle.bold())
            ProgressView()
            if let text { Text(text).foregroundStyle(.secondary) }
        }
    }
}

struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ContactsView()
                .tabItem { Label(L("Contacts"), systemImage: "person.crop.circle") }
                .tag(1)
            ChatListView()
                .tabItem { Label(L("Chats"), systemImage: "bubble.left.and.bubble.right") }
                .tag(0)
                .badge(TelegramService.shared.totalUnread)
            SettingsView()
                .tabItem { Label(L("Settings"), systemImage: "gearshape") }
                .tag(2)
        }
    }
}
