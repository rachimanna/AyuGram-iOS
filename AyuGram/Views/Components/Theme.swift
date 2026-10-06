import SwiftUI
import UIKit

/// Appearance preferences (exteraGram/AyuGram "Monet"-like accent choice → fixed iOS palette).
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    enum ThemeMode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return L("ThemeSystem")
            case .light: return L("ThemeLight")
            case .dark: return L("ThemeDark")
            }
        }
    }

    var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: "themeMode") }
    }
    var accentIndex: Int {
        didSet { UserDefaults.standard.set(accentIndex, forKey: "accentIndex") }
    }
    var messageTextSize: Double {
        didSet { UserDefaults.standard.set(messageTextSize, forKey: "messageTextSize") }
    }

    var roundedAvatars: Bool { didSet { UserDefaults.standard.set(roundedAvatars, forKey: "ayuRoundedAvatars") } }
    var compactMode: Bool { didSet { UserDefaults.standard.set(compactMode, forKey: "ayuCompactMode") } }
    var animationsEnabled: Bool { didSet { UserDefaults.standard.set(animationsEnabled, forKey: "ayuAnimations") } }
    var useCustomAccent: Bool { didSet { UserDefaults.standard.set(useCustomAccent, forKey: "ayuUseCustomAccent") } }
    var customAccentHex: String { didSet { UserDefaults.standard.set(customAccentHex, forKey: "ayuAccentHex") } }
    var localEmojiStatus: String { didSet { UserDefaults.standard.set(localEmojiStatus, forKey: "ayuLocalEmoji") } }
    var animateOwnName: Bool { didSet { UserDefaults.standard.set(animateOwnName, forKey: "ayuAnimateName") } }
    var showContactsTab: Bool { didSet { UserDefaults.standard.set(showContactsTab, forKey: "ayuShowContacts") } }
    var showCallsTab: Bool { didSet { UserDefaults.standard.set(showCallsTab, forKey: "ayuShowCalls") } }

    init() {
        roundedAvatars = UserDefaults.standard.object(forKey: "ayuRoundedAvatars") as? Bool ?? true
        compactMode = UserDefaults.standard.bool(forKey: "ayuCompactMode")
        animationsEnabled = UserDefaults.standard.object(forKey: "ayuAnimations") as? Bool ?? true
        useCustomAccent = UserDefaults.standard.bool(forKey: "ayuUseCustomAccent")
        customAccentHex = UserDefaults.standard.string(forKey: "ayuAccentHex") ?? "#7D5CFF"
        localEmojiStatus = UserDefaults.standard.string(forKey: "ayuLocalEmoji") ?? ""
        animateOwnName = UserDefaults.standard.bool(forKey: "ayuAnimateName")
        showContactsTab = UserDefaults.standard.object(forKey: "ayuShowContacts") as? Bool ?? true
        showCallsTab = UserDefaults.standard.bool(forKey: "ayuShowCalls")
        themeMode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "themeMode") ?? "") ?? .system
        accentIndex = UserDefaults.standard.object(forKey: "accentIndex") as? Int ?? 0
        messageTextSize = max(12, min(24, UserDefaults.standard.object(forKey: "messageTextSize") as? Double ?? 16))
    }

    var colorScheme: ColorScheme? {
        switch themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var accent: Color {
        if useCustomAccent, let color = Color(hex: customAccentHex) { return color }
        return Theme.accents[max(0, accentIndex) % Theme.accents.count]
    }
}

enum Theme {
    /// AyuGram purple first, then Telegram-like alternatives.
    static let accents: [Color] = [
        Color(red: 0.49, green: 0.36, blue: 1.00),  // Ayu violet
        Color(red: 0.20, green: 0.56, blue: 0.95),  // Telegram blue
        Color(red: 0.20, green: 0.71, blue: 0.47),  // green
        Color(red: 0.96, green: 0.45, blue: 0.20),  // orange
        Color(red: 0.91, green: 0.30, blue: 0.48),  // pink
        Color(red: 0.13, green: 0.64, blue: 0.70),  // cyan
    ]

    /// Telegram avatar palette (peer color ids 0…6).
    static let avatarColors: [(Color, Color)] = [
        (Color(red: 1.00, green: 0.52, blue: 0.45), Color(red: 0.89, green: 0.33, blue: 0.33)), // red
        (Color(red: 1.00, green: 0.75, blue: 0.40), Color(red: 0.96, green: 0.55, blue: 0.22)), // orange
        (Color(red: 0.73, green: 0.58, blue: 1.00), Color(red: 0.53, green: 0.40, blue: 0.91)), // violet
        (Color(red: 0.55, green: 0.86, blue: 0.43), Color(red: 0.31, green: 0.70, blue: 0.29)), // green
        (Color(red: 0.43, green: 0.86, blue: 0.89), Color(red: 0.22, green: 0.69, blue: 0.80)), // cyan
        (Color(red: 0.44, green: 0.73, blue: 1.00), Color(red: 0.25, green: 0.52, blue: 0.91)), // blue
        (Color(red: 1.00, green: 0.55, blue: 0.75), Color(red: 0.89, green: 0.35, blue: 0.56)), // pink
    ]

    static func avatarGradient(for id: Int64, colorId: Int? = nil) -> LinearGradient {
        let idx = colorId.map { $0 % 7 } ?? Int(id.magnitude % 7)
        let pair = avatarColors[max(0, min(idx, 6))]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .top, endPoint: .bottom)
    }

    static func nameColor(for id: Int64) -> Color {
        avatarColors[Int(id.magnitude % 7)].1
    }

    static let incomingBubble = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : .white })
    static let chatBackground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.06, alpha: 1) : UIColor(red: 0.89, green: 0.90, blue: 0.93, alpha: 1) })
    static let deletedTint = Color.red.opacity(0.12)
}
