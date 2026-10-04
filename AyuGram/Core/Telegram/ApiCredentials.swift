import Foundation
import Security

/// Telegram API credentials (api_id / api_hash).
///
/// AyuGram for Android ships with Telegram's official keys ("Built with official keys" from
/// Telegraher). Those keys are not ours to redistribute, so the iOS port uses the developer's
/// own credentials from https://my.telegram.org — either baked in at build time through
/// Config/Secrets.xcconfig (Info.plist TGApiId/TGApiHash) or typed in on first launch.
struct ApiCredentials: Equatable {
    var apiId: Int
    var apiHash: String

    var isValid: Bool { apiId > 0 && apiHash.count >= 16 }

    static func load() -> ApiCredentials? {
        if let stored = Keychain.read(service: service, account: "api") ,
           let parts = String(data: stored, encoding: .utf8)?.split(separator: ":"), parts.count == 2,
           let id = Int(parts[0]) {
            let c = ApiCredentials(apiId: id, apiHash: String(parts[1]))
            if c.isValid { return c }
        }
        let info = Bundle.main.infoDictionary
        if let idString = info?["TGApiId"] as? String, let id = Int(idString.trimmingCharacters(in: .whitespaces)),
           let hash = (info?["TGApiHash"] as? String)?.trimmingCharacters(in: .whitespaces) {
            let c = ApiCredentials(apiId: id, apiHash: hash)
            if c.isValid { return c }
        }
        return nil
    }

    func save() {
        Keychain.write(Data("\(apiId):\(apiHash)".utf8), service: Self.service, account: "api")
    }

    static func clear() {
        Keychain.delete(service: service, account: "api")
    }

    private static let service = "com.ayugram.port.api"
}

enum Keychain {
    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, service: String, account: String) {
        delete(service: service, account: account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
