/*
 * Port of AyuFilter.java (Copyright @Radolyn, 2023, GPL-2.0).
 * java.util.regex.Pattern (MULTILINE | CASE_INSENSITIVE) → NSRegularExpression (.anchorsMatchLines | .caseInsensitive).
 */

import Foundation

final class AyuFilter {
    static let shared = AyuFilter()

    private let lock = NSLock()
    private var patterns: [NSRegularExpression]?
    /// dialogId → messageId → filtered (same cache shape as LongSparseArray<HashMap<Integer, Boolean>>)
    private var filteredCache: [Int64: [Int64: Bool]] = [:]
    private let config: AyuConfig

    init(config: AyuConfig = .shared) {
        self.config = config
    }

    func rebuildCache() {
        lock.lock(); defer { lock.unlock() }
        patterns = Self.compile(config.regexFilters, caseInsensitive: config.regexFiltersCaseInsensitive)
        filteredCache = [:]
    }

    static func compile(_ filters: [String], caseInsensitive: Bool) -> [NSRegularExpression] {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive { options.insert(.caseInsensitive) }
        // Invalid patterns are skipped instead of crashing (Android would throw PatternSyntaxException).
        return filters.compactMap { try? NSRegularExpression(pattern: $0, options: options) }
    }

    /// Returns a human readable error if the pattern does not compile, nil when it is valid.
    static func validate(_ pattern: String) -> String? {
        guard !pattern.isEmpty else { return L("RegexFilterEmpty") }
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func matches(_ text: String, patterns: [NSRegularExpression]) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    /// Whether filters apply in this dialog at all (ChatActivity hook: channels always, other chats only with "regexFiltersInChats").
    func appliesIn(isChannel: Bool) -> Bool {
        config.regexFiltersEnabled && (config.regexFiltersInChats || isChannel)
    }

    /// AyuFilter.isFiltered(MessageObject, GroupedMessages).
    /// `groupMessageIds` are the other messages of the same album, which share the result.
    func isFiltered(text: String?, dialogId: Int64, messageId: Int64, groupMessageIds: [Int64] = []) -> Bool {
        guard config.regexFiltersEnabled else { return false }
        lock.lock(); defer { lock.unlock() }
        if patterns == nil {
            patterns = Self.compile(config.regexFilters, caseInsensitive: config.regexFiltersCaseInsensitive)
        }
        if let cached = filteredCache[dialogId]?[messageId] {
            return cached
        }
        var result = false
        if let text, !text.isEmpty, let patterns {
            result = Self.matches(text, patterns: patterns)
        }
        var bucket = filteredCache[dialogId] ?? [:]
        bucket[messageId] = result
        for id in groupMessageIds { bucket[id] = result }
        filteredCache[dialogId] = bucket
        return result
    }

    /// Drop the cached verdict for a message whose text changed.
    func invalidate(dialogId: Int64, messageId: Int64) {
        lock.lock(); defer { lock.unlock() }
        filteredCache[dialogId]?[messageId] = nil
    }
}
