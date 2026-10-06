import SwiftUI
import UIKit

extension Color {
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
    }
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#7D5CFF" }
        return String(format: "#%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}

struct CustomizationView: View {
    @State private var error = ""
    @State private var hexInput = ""
    @State private var selectedIcon = UIApplication.shared.alternateIconName ?? "Classic"
    private let icons = ["Classic", "Filled", "Sunset", "Aqua", "Rose", "Forest", "Midnight", "Gold", "Mono", "Lavender"]
    var body: some View {
        @Bindable var appearance = AppearanceSettings.shared
        Form {
            Section(L("CustomAccent")) {
                Toggle(L("UseCustomAccent"), isOn: $appearance.useCustomAccent)
                ColorPicker(L("AccentColor"), selection: Binding(get: { Color(hex: appearance.customAccentHex) ?? Theme.accents[0] }, set: { color in
                    appearance.customAccentHex = color.hexString; hexInput = color.hexString
                }), supportsOpacity: false)
                HStack {
                    TextField("#7D5CFF", text: $hexInput).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button(L("Apply")) {
                        if Color(hex: hexInput) != nil { appearance.customAccentHex = hexInput; error = "" }
                        else { error = L("InvalidHex") }
                    }
                }
            }
            Section(L("ChatDensity")) {
                Toggle(L("RoundedAvatars"), isOn: $appearance.roundedAvatars)
                Toggle(L("CompactMode"), isOn: $appearance.compactMode)
                Toggle(L("EnableAnimations"), isOn: $appearance.animationsEnabled)
                Slider(value: $appearance.messageTextSize, in: 12...24, step: 1)
                Text(L("TextSizePreview")).font(.system(size: appearance.messageTextSize))
            }
            Section {
                TextField(L("LocalEmojiStatus"), text: $appearance.localEmojiStatus)
                Toggle(L("AnimatedOwnName"), isOn: $appearance.animateOwnName)
                LocalIdentityName(name: TelegramService.shared.users[TelegramService.shared.myUserId]?.fullName ?? "AyuGram")
            } header: { Text(L("LocalIdentity")) } footer: { Text(L("LocalIdentityHint")) }
            Section(L("TabLayout")) {
                Toggle(L("ShowContactsTab"), isOn: $appearance.showContactsTab)
                Toggle(L("ShowCallsTab"), isOn: $appearance.showCallsTab)
            }
            Section(L("AppIcon")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 14) {
                    ForEach(icons, id: \.self) { name in
                        Button {
                            UIApplication.shared.setAlternateIconName(name == "Classic" ? nil : name) { failure in
                                Task { @MainActor in
                                    if let failure { error = failure.localizedDescription }
                                    selectedIcon = UIApplication.shared.alternateIconName ?? "Classic"
                                }
                            }
                        } label: {
                            VStack(spacing: 5) {
                                Image("Preview\(name)").resizable().scaledToFit().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13))
                                    .overlay { RoundedRectangle(cornerRadius: 13).stroke(selectedIcon == name ? Color.accentColor : Color.clear, lineWidth: 3) }
                                Text(name).font(.caption2).foregroundStyle(.primary)
                            }
                        }.buttonStyle(.plain).disabled(!UIApplication.shared.supportsAlternateIcons)
                    }
                }.padding(.vertical, 6)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }.navigationTitle(L("Customization"))
        .onAppear { hexInput = appearance.customAccentHex }
    }
}

struct LocalIdentityName: View {
    let name: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    private var appearance: AppearanceSettings { .shared }
    var body: some View {
        HStack(spacing: 5) {
            Text(name).foregroundStyle(LinearGradient(colors: appearance.animateOwnName ? [appearance.accent, .pink, appearance.accent] : [.primary, .primary],
                startPoint: phase ? .trailing : .leading, endPoint: phase ? .leading : .trailing))
            if !appearance.localEmojiStatus.isEmpty { Text(String(appearance.localEmojiStatus.prefix(3))) }
        }
        .onAppear { restart() }
        .onChange(of: appearance.animationsEnabled) { _, _ in restart() }
        .onChange(of: appearance.animateOwnName) { _, _ in restart() }
        .onChange(of: reduceMotion) { _, _ in restart() }
    }
    private func restart() {
        phase = false
        guard appearance.animateOwnName, appearance.animationsEnabled, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { phase = true }
    }
}
