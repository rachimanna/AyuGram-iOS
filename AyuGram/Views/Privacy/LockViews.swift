import SwiftUI

struct PINUnlockView: View {
    var vault = false
    var onUnlocked: () -> Void = {}
    @State private var pin = ""
    @State private var error = ""
    @State private var busy = false
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: vault ? "lock.rectangle.stack" : "lock.shield").font(.system(size: 54)).foregroundStyle(.tint)
            Text(L(vault ? "UnlockHiddenChats" : "UnlockApp")).font(.title2.bold())
            SecureField(L("LocalPIN"), text: $pin).keyboardType(.numberPad).textContentType(.password)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260).onSubmit { unlock() }
            if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
            Button(L("Unlock")) { unlock() }.buttonStyle(.borderedProminent).disabled(busy || pin.isEmpty)
            if !vault, AppLock.shared.biometrics {
                Button { Task { busy = true; if await AppLock.shared.unlockBiometric() { onUnlocked() }; busy = false } } label: {
                    Label(L("UnlockBiometric"), systemImage: "faceid")
                }.disabled(busy)
            }
            if busy { ProgressView() }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
    }
    private func unlock() {
        Task {
            busy = true
            if await AppLock.shared.unlock(pin, vault: vault) { pin = ""; error = ""; onUnlocked() }
            else { error = Date() < AppLock.shared.retryAfter ? L("PINRetryLater") : L("WrongPIN"); pin = "" }
            busy = false
        }
    }
}

/// Route gating covers notifications, search, archives, profiles and deleted history.
struct ChatAccessGate<Content: View>: View {
    let chatId: Int64
    @ViewBuilder let content: () -> Content
    var body: some View {
        if let chat = TelegramService.shared.chats[chatId], !AppLock.shared.visible(chat) {
            PINUnlockView(vault: true)
        } else if TelegramService.shared.chats[chatId] == nil && !AppLock.shared.mayRevealUnknownChat(chatId) {
            PINUnlockView(vault: true)
        } else if AppLock.shared.canShowContent {
            content()
        } else { Color(uiColor: .systemBackground) }
    }
}

struct DecoyView: View {
    var body: some View {
        TabView {
            NavigationStack { ContentUnavailableView(L("NoChats"), systemImage: "bubble.left.and.bubble.right").navigationTitle(L("Chats")) }
                .tabItem { Label(L("Chats"), systemImage: "bubble.left.and.bubble.right") }
            NavigationStack {
                List { LabeledContent(L("AppName"), value: "AyuGram"); Button(L("LockNow")) { AppLock.shared.lock() } }
                    .navigationTitle(L("Settings"))
            }.tabItem { Label(L("Settings"), systemImage: "gearshape") }
        }
    }
}

struct PINEditorView: View {
    let kind: String
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var error = ""
    @State private var busy = false
    private var requiresCurrent: Bool { kind == "vault" ? AppLock.shared.hasVaultPIN : AppLock.shared.enabled }
    var body: some View {
        Form {
            if requiresCurrent { Section(L("CurrentPIN")) { SecureField(L("CurrentPIN"), text: $current).keyboardType(.numberPad) } }
            Section {
                SecureField(L("NewPIN"), text: $pin).keyboardType(.numberPad)
                SecureField(L("ConfirmPIN"), text: $confirmation).keyboardType(.numberPad)
            } footer: { Text(L("PINRequirements")) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            Button(L("Save")) { save(remove: false) }.disabled(busy)
            if requiresCurrent {
                Button(L("RemovePIN"), role: .destructive) { save(remove: true) }.disabled(busy)
            }
            if busy { ProgressView() }
        }.navigationTitle(L(kind == "app" ? "AppPIN" : kind == "duress" ? "DuressPIN" : "HiddenChatsPIN"))
    }
    private func save(remove: Bool) {
        guard remove || pin == confirmation else { error = L("PINMismatch"); return }
        Task {
            busy = true
            do { try await AppLock.shared.setPIN(remove ? nil : pin, kind: kind, current: current); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct SecuritySettingsView: View {
    var body: some View {
        @Bindable var lock = AppLock.shared
        if lock.hasVaultPIN && !lock.vaultUnlocked { PINUnlockView(vault: true) }
        else { Form {
            Section {
                NavigationLink(L("AppPIN")) { PINEditorView(kind: "app") }
                Toggle(L("UseBiometrics"), isOn: $lock.biometrics).disabled(!lock.enabled)
                Picker(L("AutoLockTimeout"), selection: $lock.timeout) {
                    Text(L("Immediately")).tag(0)
                    Text(L("After30Seconds")).tag(30)
                    Text(L("After1Minute")).tag(60)
                    Text(L("After5Minutes")).tag(300)
                }
                Button(L("LockNow")) { lock.lock() }.disabled(!lock.enabled)
            } footer: { Text(L("LocalLockHint")) }
            Section {
                NavigationLink(L("HiddenChatsPIN")) { PINEditorView(kind: "vault") }
                NavigationLink(L("DuressPIN")) { PINEditorView(kind: "duress") }.disabled(!lock.enabled)
            } footer: { Text(L("DuressPINHint")) }
            Section(L("ProtectedFolders")) {
                ForEach(TelegramService.shared.folders) { folder in
                    Toggle(folder.title, isOn: Binding(get: { PrivacyPreferences.shared.snapshot.lockedFolders.contains(folder.id) }, set: { on in
                        if on { PrivacyPreferences.shared.snapshot.lockedFolders.append(folder.id) }
                        else { PrivacyPreferences.shared.snapshot.lockedFolders.removeAll { $0 == folder.id } }
                    })).disabled(!lock.hasVaultPIN)
                }
                if !lock.hasVaultPIN { Text(L("ConfigureVaultFirst")).font(.footnote).foregroundStyle(.secondary) }
            }
        }.navigationTitle(L("PrivacyAndSecurity")) }
    }
}
