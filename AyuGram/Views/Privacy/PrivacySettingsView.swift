import PhotosUI
import SwiftUI
import UIKit

struct PrivacySettingsView: View {
    var body: some View {
        @Bindable var privacy = PrivacyPreferences.shared
        Form {
            Section(L("Privacy")) {
                Toggle(L("SuppressTyping"), isOn: $privacy.snapshot.suppressTyping)
                Toggle(L("HideOwnPresence"), isOn: $privacy.snapshot.hideOwnPresence)
                Toggle(L("HideOwnPhone"), isOn: $privacy.snapshot.hideOwnPhone)
            }
            Section {
                Toggle(L("ShieldSecretCapture"), isOn: $privacy.snapshot.shieldSecretCapture)
            } footer: { Text(L("SecretCaptureHint")) }
            Section(L("HistoryNotifications")) {
                Toggle(L("NotifyEdits"), isOn: $privacy.snapshot.notifyEdits)
                Toggle(L("NotifyDeletions"), isOn: $privacy.snapshot.notifyDeletions)
            }
            Section {
                Toggle(L("KeepViewedMedia"), isOn: $privacy.snapshot.keepViewedEphemeralMedia)
                NavigationLink(L("ViewedMediaArchive")) { UnifiedHistoryView(retained: true) }
                Toggle(L("KeepCallLog"), isOn: $privacy.snapshot.keepCallLog)
                NavigationLink(L("CallLog")) { CallLogView() }
            } footer: { Text(L("ViewedMediaHint")) }
        }.navigationTitle(L("Privacy"))
    }
}

struct ChatPrivacyView: View {
    let chatId: Int64
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var error = ""
    private var settings: ChatPrivacy { PrivacyPreferences.shared.chat(chatId) }
    private func binding<T>(_ key: WritableKeyPath<ChatPrivacy, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: { value in PrivacyPreferences.shared.update(chatId) { $0[keyPath: key] = value } })
    }
    var body: some View {
        Form {
            Section {
                Picker(L("GhostModeTitle"), selection: binding(\.ghost)) {
                    Text(L("UseGlobalSetting")).tag(ChatPrivacy.Ghost.inherit)
                    Text(L("Enabled")).tag(ChatPrivacy.Ghost.on)
                    Text(L("Disabled")).tag(ChatPrivacy.Ghost.off)
                }
            } footer: { Text(L("ChatGhostHint")) }
            Section {
                Picker(L("DelayedRead"), selection: binding(\.readDelay)) {
                    Text(L("Immediately")).tag(0)
                    Text(L("ReadByButton")).tag(-1)
                    ForEach([5, 10, 30, 60, 300], id: \.self) { Text(LF("SecondsCount", $0)).tag($0) }
                }
            } footer: { Text(L("DelayedReadHint")) }
            Section {
                Toggle(L("HideChatBehindPIN"), isOn: binding(\.hidden)).disabled(!AppLock.shared.hasVaultPIN)
                if !AppLock.shared.hasVaultPIN { NavigationLink(L("HiddenChatsPIN")) { PINEditorView(kind: "vault") } }
            }
            Section {
                Picker(L("AutoDeleteOwnMessages"), selection: Binding(get: { settings.autoDeleteSeconds }, set: { value in
                    PrivacyPreferences.shared.update(chatId) { $0.autoDeleteSeconds = value }
                    if value == 0 { LocalAutomation.shared.cancelTimers(chatId: chatId) }
                })) {
                    Text(L("Disabled")).tag(0)
                    ForEach([60, 300, 3600, 86400, 604800], id: \.self) { Text(LF("SecondsCount", $0)).tag($0) }
                }
                if let failure = LocalAutomation.shared.lastError { Text(failure).foregroundStyle(.red) }
            } footer: { Text(L("AutoDeleteLocalHint")) }
            Section(L("ChatWallpaper")) {
                ColorPicker(L("WallpaperColor"), selection: Binding(get: { Color(hex: settings.wallpaperHex) ?? Theme.chatBackground }, set: { color in
                    PrivacyPreferences.shared.update(chatId) { $0.wallpaperHex = color.hexString }
                }), supportsOpacity: false)
                PhotosPicker(selection: $selectedPhoto, matching: .images) { Label(L("WallpaperPhoto"), systemImage: "photo") }
                Button(L("ResetWallpaper")) {
                    removeWallpaper(); PrivacyPreferences.shared.update(chatId) { $0.wallpaperHex = ""; $0.wallpaperFile = "" }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }.navigationTitle(L("ChatPrivacy"))
        .onChange(of: selectedPhoto) { _, item in
            let account = PrivacyPreferences.shared.accountId
            Task {
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                    guard account == PrivacyPreferences.shared.accountId else { return }
                    let ratio = min(1, 2048 / max(image.size.width, image.size.height))
                    let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let jpeg = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
                    guard let jpeg else { return }
                    let directory = AyuConstants.applicationSupport.appendingPathComponent("Wallpapers", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent("\(account)_\(chatId)_\(UUID().uuidString).jpg")
                    try jpeg.write(to: file, options: [.atomic, .completeFileProtection])
                    removeWallpaper(); PrivacyPreferences.shared.update(chatId) { $0.wallpaperFile = file.lastPathComponent }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func removeWallpaper() {
        guard !settings.wallpaperFile.isEmpty else { return }
        let url = AyuConstants.applicationSupport.appendingPathComponent("Wallpapers").appendingPathComponent(settings.wallpaperFile)
        try? FileManager.default.removeItem(at: url)
    }
}

struct ChatWallpaper: View {
    let chatId: Int64
    @State private var image: UIImage?
    private var settings: ChatPrivacy { PrivacyPreferences.shared.chat(chatId) }
    var body: some View {
        ZStack {
            (Color(hex: settings.wallpaperHex) ?? Theme.chatBackground)
            if let image { Image(uiImage: image).resizable().scaledToFill().opacity(0.75) }
        }.clipped().ignoresSafeArea()
        .task(id: settings.wallpaperFile) {
            image = nil
            guard !settings.wallpaperFile.isEmpty else { return }
            let path = AyuConstants.applicationSupport.appendingPathComponent("Wallpapers").appendingPathComponent(settings.wallpaperFile).path
            image = await ImageCache.shared.load(path: path, maxPixel: 2048)
        }
    }
}
