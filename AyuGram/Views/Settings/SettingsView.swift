import SwiftUI

/// Settings (Telegram/exteraGram settings screen + entry to AyuGram Preferences).
struct SettingsView: View {
    @Environment(TelegramService.self) private var service
    @Environment(AyuConfig.self) private var ayu
    @State private var confirmLogout = false

    private var me: UserItem? { service.users[service.myUserId] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AvatarView(id: service.myUserId, title: me?.fullName ?? "", photo: me?.photo, size: 64, colorId: me?.accentColorId)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(me?.fullName ?? "").font(.title3.bold())
                                // AyuGram "Local Telegram Premium" (client-side only, like on Android).
                                if me?.isPremium == true || ayu.localPremium {
                                    PremiumBadge()
                                }
                            }
                            if let phone = me?.phoneNumber, !phone.isEmpty { Text("+" + phone).foregroundStyle(.secondary) }
                            if let username = me?.username { Text("@" + username).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    NavigationLink { LocalPremiumView() } label: { PremiumSettingsCard() }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section(L("QuickActions")) {
                    Toggle(isOn: Binding(get: { ayu.isGhostModeActive }, set: { ayu.setGhostMode($0) })) {
                        Label { Text(L("GhostModeToggle")) } icon: {
                            GhostGlyph(active: ayu.isGhostModeActive).frame(width: 24, height: 24)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        AyuPreferencesView()
                    } label: {
                        Label { Text(L("AyuPreferences")) } icon: { GhostGlyph().frame(width: 24, height: 24) }
                    }
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        Label(L("Appearance"), systemImage: "paintbrush")
                    }
                    NavigationLink {
                        StorageView()
                    } label: {
                        Label(L("DataAndStorage"), systemImage: "internaldrive")
                    }
                    NavigationLink {
                        SessionsInfoView()
                    } label: {
                        Label(L("Devices"), systemImage: "laptopcomputer.and.iphone")
                    }
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label(L("About"), systemImage: "info.circle")
                    }
                }

                Section {
                    Button(L("LogOut"), role: .destructive) { confirmLogout = true }
                }
            }
            .navigationTitle(L("Settings"))
            .confirmationDialog(L("LogOutConfirm"), isPresented: $confirmLogout, titleVisibility: .visible) {
                Button(L("LogOut"), role: .destructive) { Task { await service.logOut() } }
            }
        }
    }
}

struct AppearanceView: View {
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        @Bindable var appearance = appearance
        Form {
            Section(L("Theme")) {
                Picker(L("Theme"), selection: $appearance.themeMode) {
                    ForEach(AppearanceSettings.ThemeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(L("AccentColor")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 14) {
                    ForEach(Theme.accents.indices, id: \.self) { i in
                        Button { appearance.accentIndex = i } label: {
                            Circle()
                                .fill(Theme.accents[i])
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if AppearanceSettings.validAccentIndex(appearance.accentIndex) == i {
                                        Image(systemName: "checkmark").foregroundStyle(.white).bold()
                                    }
                                }
                                .frame(minWidth: 44, minHeight: 44)
                            }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("AccentColor") + " \(i + 1)")
                    }
                }
                .padding(.vertical, 6)
            }
            Section(L("TextSize")) {
                Slider(value: $appearance.messageTextSize, in: 12...24, step: 1)
                Text(L("TextSizePreview")).font(.system(size: appearance.messageTextSize))
            }
            Section {
                NavigationLink { LocalPremiumView() } label: {
                    Label("Ayu Premium", systemImage: "star.fill")
                }
            }
        }
        .navigationTitle(L("Appearance"))
    }
}

struct StorageView: View {
    @Environment(TelegramService.self) private var service
    @State private var usage: (files: Int64, database: Int64)?
    @State private var attachmentsSize: Int64 = 0
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                if let usage {
                    LabeledContent(L("CacheFiles"), value: Formatters.fileSize(usage.files))
                    LabeledContent(L("CacheDatabase"), value: Formatters.fileSize(usage.database))
                } else {
                    ProgressView()
                }
                LabeledContent(L("SavedAttachments"), value: Formatters.fileSize(attachmentsSize))
            } footer: {
                Text(L("SavedAttachmentsHint"))
            }
            Section {
                Button(L("ClearCache"), role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle(L("DataAndStorage"))
        .task { await refresh() }
        .confirmationDialog(L("ClearCacheConfirm"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("ClearCache"), role: .destructive) {
                Task {
                    await service.clearCache()
                    await refresh()
                }
            }
        }
    }

    private func refresh() async {
        usage = await service.storageUsage()
        attachmentsSize = Self.directorySize(AyuConstants.attachmentsDirectory)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Active sessions (SessionsActivity).
struct SessionsInfoView: View {
    @Environment(TelegramService.self) private var service
    @State private var sessions: [SessionItem] = []
    @State private var errorText: String?

    var body: some View {
        List {
            if let current = sessions.first(where: \.isCurrent) {
                Section(L("ThisDevice")) { row(current) }
            }
            let others = sessions.filter { !$0.isCurrent }
            if !others.isEmpty {
                Section(L("ActiveSessions")) {
                    ForEach(others) { s in
                        row(s).swipeActions {
                            Button(L("Terminate"), role: .destructive) {
                                Task {
                                    do {
                                        try await service.terminateSession(s.id)
                                        sessions.removeAll { $0.id == s.id }
                                    } catch {
                                        errorText = TelegramService.describe(error)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if let errorText { Text(errorText).foregroundStyle(.red) }
        }
        .navigationTitle(L("Devices"))
        .task { sessions = await service.activeSessions() }
        .refreshable { sessions = await service.activeSessions() }
    }

    private func row(_ s: SessionItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.title).font(.headline)
            Text(s.device).font(.subheadline)
            Text(s.location).font(.caption).foregroundStyle(.secondary)
            if !s.isCurrent { Text(Formatters.fullDateTime(s.lastActive)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    GhostGlyph().frame(width: 64, height: 64)
                    Text("AyuGram for iOS").font(.title2.bold())
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · TDLib 1.8.67")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section(L("AboutCredits")) {
                Link("AyuGram4A — Radolyn", destination: URL(string: "https://github.com/AyuGram/AyuGram4A")!)
                Link("exteraGram", destination: URL(string: "https://github.com/exteraSquad/exteraGram")!)
                Link("Telegram for Android", destination: URL(string: "https://github.com/DrKLO/Telegram")!)
                Link("TDLib", destination: URL(string: "https://github.com/tdlib/td")!)
                Link("TDLibKit", destination: URL(string: "https://github.com/Swiftgram/TDLibKit")!)
                Link("libopus / libogg", destination: URL(string: "https://opus-codec.org")!)
            }
            Section {
                Text(L("AboutLicense")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("About"))
    }
}
