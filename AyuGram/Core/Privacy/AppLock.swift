import CommonCrypto
import Foundation
import LocalAuthentication
import Observation
import Security
import SwiftUI
import UserNotifications

/// Salted PBKDF2 records live only in ThisDeviceOnly Keychain, never in UserDefaults.
struct PINRecord: Codable, Sendable {
    let salt: Data
    let digest: Data
    static func make(_ pin: String) throws -> PINRecord {
        guard pin.count >= 4, pin.count <= 12, pin.allSatisfy(\.isNumber), pin.allSatisfy({ $0.isASCII }) else { throw LockError.invalidPIN }
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw LockError.keychain }
        return PINRecord(salt: salt, digest: try derive(pin, salt: salt))
    }
    func matches(_ pin: String) -> Bool {
        guard let candidate = try? Self.derive(pin, salt: salt), candidate.count == digest.count else { return false }
        return zip(candidate, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func derive(_ pin: String, salt: Data) throws -> Data {
        var result = Data(count: 32)
        let password = Array(pin.utf8)
        let status = result.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passBytes.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 120_000,
                        output.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw LockError.keychain }
        return result
    }
}
enum LockError: Error, LocalizedError {
    case invalidPIN, keychain, wrongPIN, samePIN
    var errorDescription: String? {
        switch self {
        case .invalidPIN: return L("PINRequirements")
        case .keychain: return L("PINStorageError")
        case .wrongPIN: return L("WrongPIN")
        case .samePIN: return L("PINMustDiffer")
        }
    }
}

enum LockKeychain {
    static let service = "com.ayugram.local-lock.v2"
    static func read(_ name: String) -> PINRecord? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PINRecord.self, from: data)
    }
    static func write(_ record: PINRecord?, name: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        if let record {
            let data = try JSONEncoder().encode(record)
            let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if update == errSecItemNotFound {
                var add = query; attributes.forEach { add[$0.key] = $0.value }
                guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw LockError.keychain }
            } else if update != errSecSuccess { throw LockError.keychain }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw LockError.keychain }
        }
    }
}

@MainActor @Observable
final class AppLock {
    static let shared = AppLock()
    private(set) var appUnlocked: Bool
    private(set) var vaultUnlocked = false
    private(set) var decoy = false
    var curtain = false
    var biometrics: Bool { didSet { UserDefaults.standard.set(biometrics, forKey: "ayuBiometrics") } }
    var timeout: Int { didSet { UserDefaults.standard.set(timeout, forKey: "ayuLockTimeout") } }
    private(set) var revision = 0
    private(set) var retryAfter = Date.distantPast
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var backgroundAt: Date?
    @ObservationIgnored private var biometricContext: LAContext?
    @ObservationIgnored private var session = UUID()
    var enabled: Bool { _ = revision; return UserDefaults.standard.bool(forKey: "ayuAppLockEnabled") }
    var hasVaultPIN: Bool { _ = revision; return UserDefaults.standard.bool(forKey: "ayuVaultLockEnabled") }
    var canShowContent: Bool { appUnlocked && !decoy && !curtain }
    private init() {
        appUnlocked = !UserDefaults.standard.bool(forKey: "ayuAppLockEnabled")
        biometrics = UserDefaults.standard.bool(forKey: "ayuBiometrics")
        timeout = UserDefaults.standard.object(forKey: "ayuLockTimeout") as? Int ?? 0
    }
    func setPIN(_ pin: String?, kind: String, current: String) async throws {
        guard ["app", "vault", "duress"].contains(kind) else { throw LockError.keychain }
        let existing = LockKeychain.read(kind == "duress" ? "app" : kind)
        let required = kind == "vault" ? hasVaultPIN : enabled
        if required {
            guard let existing else { throw LockError.keychain }
            guard await Task.detached(priority: .userInitiated, operation: { existing.matches(current) }).value else { throw LockError.wrongPIN }
        }
        if kind == "duress", !enabled { throw LockError.wrongPIN }
        if let pin {
            let other = LockKeychain.read(kind == "duress" ? "app" : "duress")
            if let other, await Task.detached(operation: { other.matches(pin) }).value { throw LockError.samePIN }
            let record = try await Task.detached(priority: .userInitiated) { try PINRecord.make(pin) }.value
            try LockKeychain.write(record, name: kind)
        } else {
            if kind == "app" { try LockKeychain.write(nil, name: "duress") }
            try LockKeychain.write(nil, name: kind)
            if kind == "vault" {
                // Removing the vault PIN also removes protection flags, so no chat becomes inaccessible.
                for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("ayuPrivacy.v2.") {
                    guard let data = value as? Data, var snapshot = try? JSONDecoder().decode(PrivacySnapshot.self, from: data) else { continue }
                    snapshot.lockedFolders = []
                    for id in Array(snapshot.chats.keys) { snapshot.chats[id]?.hidden = false }
                    if let updated = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(updated, forKey: key) }
                }
                PrivacyPreferences.shared.snapshot.lockedFolders = []
                for id in Array(PrivacyPreferences.shared.snapshot.chats.keys) { PrivacyPreferences.shared.snapshot.chats[id]?.hidden = false }
            }
        }
        if kind == "app" { UserDefaults.standard.set(pin != nil, forKey: "ayuAppLockEnabled"); appUnlocked = true }
        if kind == "vault" { UserDefaults.standard.set(pin != nil, forKey: "ayuVaultLockEnabled"); vaultUnlocked = pin != nil }
        revision += 1
    }
    func unlock(_ pin: String, vault: Bool) async -> Bool {
        guard Date() >= retryAfter else { return false }
        let token = session
        let record = LockKeychain.read(vault ? "vault" : "app")
        let duress = vault ? nil : LockKeychain.read("duress")
        let result = await Task.detached(priority: .userInitiated) { () -> Int in
            if let duress, duress.matches(pin) { return 2 }
            if let record, record.matches(pin) { return 1 }
            return 0
        }.value
        guard token == session else { return false }
        guard result > 0 else {
            failures += 1
            if failures >= 5 { retryAfter = Date().addingTimeInterval(min(300, pow(2, Double(min(failures, 12)))) ) }
            return false
        }
        failures = 0; retryAfter = .distantPast
        if vault { vaultUnlocked = true }
        else {
            decoy = result == 2; appUnlocked = true
            if decoy {
                vaultUnlocked = false
                AppRouter.shared.chatPath = []; AppRouter.shared.selectedTab = 0
                TelegramService.shared.cancelPendingReads()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            }
            TelegramService.shared.setAppActive(!decoy)
        }
        return true
    }
    func unlockBiometric() async -> Bool {
        guard enabled, biometrics, !decoy else { return false }
        let token = session
        let context = LAContext(); context.localizedFallbackTitle = ""; biometricContext = context
        defer { biometricContext = nil }
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: L("UnlockApp")), token == session else { return false }
            appUnlocked = true; decoy = false; failures = 0
            TelegramService.shared.setAppActive(true)
            return true
        } catch { return false }
    }
    func lock() {
        session = UUID(); biometricContext?.invalidate(); vaultUnlocked = false; decoy = false
        appUnlocked = !enabled
        AppRouter.shared.chatPath = []
        TelegramService.shared.cancelPendingReads()
        TelegramService.shared.setAppActive(false)
    }
    func phaseChanged(_ phase: ScenePhase) {
        curtain = phase != .active
        if phase == .background {
            backgroundAt = Date(); session = UUID(); biometricContext?.invalidate()
            vaultUnlocked = false
            AppRouter.shared.chatPath = []
            TelegramService.shared.cancelPendingReads()
            if timeout == 0 { lock() }
        } else if phase == .active {
            if let date = backgroundAt, Date().timeIntervalSince(date) >= Double(timeout) { lock() }
            backgroundAt = nil
        }
    }
    func accountChanged() { vaultUnlocked = false; session = UUID(); AppRouter.shared.chatPath = [] }
    func mayRevealUnknownChat(_ id: Int64) -> Bool {
        !decoy && (vaultUnlocked || (!PrivacyPreferences.shared.chat(id).hidden && PrivacyPreferences.shared.snapshot.lockedFolders.isEmpty))
    }
    func visible(_ chat: ChatItem) -> Bool {
        !decoy && (!PrivacyPreferences.shared.isProtected(chat.id, positions: chat.positions) || vaultUnlocked)
    }
}
