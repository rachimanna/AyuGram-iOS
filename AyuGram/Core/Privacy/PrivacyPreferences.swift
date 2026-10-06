import Foundation
import Observation

struct ChatPrivacy: Codable, Equatable {
    enum Ghost: String, Codable, CaseIterable { case inherit, on, off }
    var ghost: Ghost = .inherit
    /// -1 = manual, 0 = immediate, positive = seconds.
    var readDelay: Int = 0
    var hidden = false
    var autoDeleteSeconds: Int = 0
    var wallpaperHex = ""
    var wallpaperFile = ""
}

struct PrivacySnapshot: Codable {
    var chats: [String: ChatPrivacy] = [:]
    var lockedFolders: [Int] = []
    var suppressTyping = false
    var hideOwnPresence = false
    var hideOwnPhone = false
    var notifyEdits = false
    var notifyDeletions = false
    var keepViewedEphemeralMedia = false
    var shieldSecretCapture = true
    var keepCallLog = true
}

@MainActor @Observable
final class PrivacyPreferences {
    static let shared = PrivacyPreferences()
    private(set) var accountId: Int64 = 0
    var snapshot = PrivacySnapshot() { didSet { persist() } }
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func selectAccount(_ id: Int64) {
        guard id != accountId else { return }
        accountId = id
        snapshot = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PrivacySnapshot.self, from: $0) } ?? PrivacySnapshot()
    }
    private var key: String { "ayuPrivacy.v2.\(accountId)" }
    private func persist() {
        guard accountId != 0, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: .ayuPrivacyChanged, object: nil)
    }
    func chat(_ id: Int64) -> ChatPrivacy { snapshot.chats[String(id)] ?? ChatPrivacy() }
    func update(_ id: Int64, _ change: (inout ChatPrivacy) -> Void) {
        var value = chat(id); change(&value); snapshot.chats[String(id)] = value
    }
    func isGhost(_ id: Int64, config: AyuConfig = .shared) -> Bool {
        switch chat(id).ghost {
        case .inherit: return config.isGhostModeActive
        case .on: return true
        case .off: return false
        }
    }
    func sendsRead(_ id: Int64, config: AyuConfig = .shared) -> Bool {
        switch chat(id).ghost {
        case .inherit: return config.sendReadPackets
        case .on: return false
        case .off: return true
        }
    }
    func sendsTyping(_ id: Int64, config: AyuConfig = .shared) -> Bool {
        !snapshot.suppressTyping && !isGhost(id, config: config)
    }
    func isProtected(_ id: Int64, positions: [ChatListKey: ChatPositionItem] = [:]) -> Bool {
        chat(id).hidden || positions.keys.contains { key in
            if case .folder(let folder) = key { return snapshot.lockedFolders.contains(folder) }
            return false
        }
    }
}

extension Notification.Name {
    static let ayuPrivacyChanged = Notification.Name("AyuPrivacyChanged")
    static let ayuHistoryChanged = Notification.Name("AyuHistoryChanged")
}
