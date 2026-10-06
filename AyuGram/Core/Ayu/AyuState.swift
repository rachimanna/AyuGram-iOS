/*
 * Port of AyuState.java / AyuStateVariable.java (Copyright @Radolyn, 2023, GPL-2.0).
 *
 * On Android these flags let a single packet through the ConnectionsManager interceptor
 * ("allow one read packet", "this send was auto-scheduled"). With TDLib the app decides
 * explicitly whether to issue a request, so only the delete-permission list is needed:
 * messages the user deletes himself must not be stored as "deleted".
 */

import Foundation

final class AyuState {
    static let shared = AyuState()
    private let lock = NSLock()
    private var deletePermitted: [Int64: Set<Int64>] = [:]

    func permitDeleteMessages(chatId: Int64, messageIds: [Int64]) {
        lock.lock(); defer { lock.unlock() }
        deletePermitted[chatId, default: []].formUnion(messageIds)
    }

    func isDeletePermitted(chatId: Int64, messageId: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let until = suppressedChats[chatId], until > Date() { return true }
        return deletePermitted[chatId]?.contains(messageId) ?? false
    }

    /// The user cleared the whole history himself: don't treat the resulting deletions as "deleted by someone".
    private var suppressedChats: [Int64: Date] = [:]

    func permitDeleteWholeChat(chatId: Int64, for seconds: TimeInterval = 30) {
        lock.lock(); defer { lock.unlock() }
        suppressedChats[chatId] = Date().addingTimeInterval(seconds)
    }

    func messageDeleted(chatId: Int64, messageId: Int64) {
        lock.lock(); defer { lock.unlock() }
        deletePermitted[chatId]?.remove(messageId)
    }
}

/// AyuGhostUtils.markReadLocally on Android writes the read marker into Telegram's local DB
/// without telling the server. TDLib has no "local only" read, so the port keeps its own
/// per-chat marker and the UI treats everything up to it as read.
final class LocalReadStore {
    static let shared = LocalReadStore()
    private let defaults: UserDefaults
    private var key = "ayuLocalReadUntil"
    private var cache: [Int64: Int64]

    init(defaults: UserDefaults = UserDefaults(suiteName: "ayuconfig") ?? .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: key) as? [String: Int64] ?? [:]
        cache = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int64(k).map { ($0, v) } })
    }

    func selectAccount(_ id: Int64) {
        let nextKey = "ayuLocalReadUntil.account.\(id)"
        guard key != nextKey else { return }
        if id != 0 && !defaults.bool(forKey: "ayuLocalReadMigrated") {
            if let legacy = defaults.dictionary(forKey: "ayuLocalReadUntil") { defaults.set(legacy, forKey: nextKey) }
            defaults.removeObject(forKey: "ayuLocalReadUntil")
            defaults.set(true, forKey: "ayuLocalReadMigrated")
        }
        key = nextKey
        let raw = defaults.dictionary(forKey: key) as? [String: Int64] ?? [:]
        cache = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int64(k).map { ($0, v) } })
    }

    func readUntil(chatId: Int64) -> Int64 { cache[chatId] ?? 0 }

    func markRead(chatId: Int64, until messageId: Int64) {
        guard messageId > (cache[chatId] ?? 0) else { return }
        cache[chatId] = messageId
        persist()
    }

    func clear(chatId: Int64) {
        cache[chatId] = nil
        persist()
    }

    private func persist() {
        defaults.set(Dictionary(uniqueKeysWithValues: cache.map { (String($0.key), $0.value) }), forKey: key)
    }
}
