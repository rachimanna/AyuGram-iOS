/*
 * Port of AyuData / AyuDatabase (Room) + DeletedMessageDao + EditedMessageDao
 * (Copyright @Radolyn, 2023, GPL-2.0) to plain SQLite.
 *
 * Tables keep the Android entity names and columns (deletedmessage, editedmessage,
 * deletedmessagereaction). The full message is additionally stored as a JSON payload of
 * MessageItem, which replaces the TL-serialized blobs (textEntities, documentSerialized, …).
 *
 * The extra table `messagecache` exists only on iOS: Android reads the original message out of
 * Telegram's own local DB at the moment of deletion; TDLib drops it before notifying us,
 * so the port keeps a copy of every message it has seen.
 */

import Foundation

final class AyuDatabase {
    static let schemaVersion: Int64 = 1

    let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(path: String, journalMode: String) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute("PRAGMA journal_mode=\(journalMode == "WAL" ? "WAL" : "DELETE");")
        try db.execute("PRAGMA synchronous=NORMAL;")
        migrate()
    }

    static func defaultPath() -> String {
        AyuConstants.applicationSupport.appendingPathComponent("\(AyuConstants.ayuDatabase).sqlite").path
    }

    private func migrate() {
        let version = (try? db.scalarInt("PRAGMA user_version")) ?? 0
        guard version < Self.schemaVersion else { return }
        do {
            try db.transaction {
                // Columns of AyuMessageBase.
                let base = """
                    userId INTEGER NOT NULL, dialogId INTEGER NOT NULL, groupedId INTEGER NOT NULL DEFAULT 0,
                    peerId INTEGER NOT NULL DEFAULT 0, fromId INTEGER NOT NULL DEFAULT 0, topicId INTEGER NOT NULL DEFAULT 0,
                    messageId INTEGER NOT NULL, date INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0,
                    editDate INTEGER NOT NULL DEFAULT 0, views INTEGER NOT NULL DEFAULT 0,
                    fwdName TEXT, replyMessageId INTEGER NOT NULL DEFAULT 0,
                    entityCreateDate INTEGER NOT NULL DEFAULT 0, text TEXT,
                    mediaPath TEXT, documentType INTEGER NOT NULL DEFAULT 0, mimeType TEXT,
                    payload BLOB
                    """
                try db.execute("CREATE TABLE IF NOT EXISTS deletedmessage (fakeId INTEGER PRIMARY KEY AUTOINCREMENT, \(base));")
                try db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_deleted_unique ON deletedmessage(userId, dialogId, topicId, messageId);")
                try db.execute("CREATE INDEX IF NOT EXISTS idx_deleted_grouped ON deletedmessage(userId, dialogId, groupedId);")
                try db.execute("CREATE TABLE IF NOT EXISTS editedmessage (fakeId INTEGER PRIMARY KEY AUTOINCREMENT, \(base));")
                try db.execute("CREATE INDEX IF NOT EXISTS idx_edited_msg ON editedmessage(userId, dialogId, messageId, entityCreateDate);")
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS deletedmessagereaction (
                        fakeReactionId INTEGER PRIMARY KEY AUTOINCREMENT, deletedMessageId INTEGER NOT NULL,
                        emoticon TEXT, documentId INTEGER NOT NULL DEFAULT 0, isCustom INTEGER NOT NULL DEFAULT 0,
                        count INTEGER NOT NULL DEFAULT 0, selfSelected INTEGER NOT NULL DEFAULT 0);
                    """)
                try db.execute("CREATE INDEX IF NOT EXISTS idx_reaction_msg ON deletedmessagereaction(deletedMessageId);")
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS messagecache (
                        userId INTEGER NOT NULL, dialogId INTEGER NOT NULL, messageId INTEGER NOT NULL,
                        date INTEGER NOT NULL, cachedAt INTEGER NOT NULL, payload BLOB NOT NULL,
                        PRIMARY KEY (userId, dialogId, messageId));
                    """)
                try db.execute("CREATE INDEX IF NOT EXISTS idx_cache_age ON messagecache(cachedAt);")
                try db.execute("PRAGMA user_version = \(Self.schemaVersion);")
            }
        } catch {
            AppLog.error("AyuDatabase migration failed: \(error)")
        }
    }

    // MARK: - Encoding

    private func encode(_ message: MessageItem) -> Data? {
        var m = message
        m.ayuDeleted = false
        m.ayuHasRevisions = false
        return try? encoder.encode(m)
    }

    private func decode(_ data: Data?) -> MessageItem? {
        guard let data else { return nil }
        return try? decoder.decode(MessageItem.self, from: data)
    }

    private func baseValues(userId: Int64, message m: MessageItem, entityCreateDate: Int, mediaPath: String?) -> [SQLiteDatabase.Value] {
        var mime: String?
        if case .document(let d, _) = m.body { mime = d.mimeType }
        if case .audio(let a, _) = m.body { mime = a.mimeType }
        return [
            .int(userId), .int(m.chatId), .int(m.mediaAlbumId), .int(m.chatId), .int(m.sender.id), .int(m.topicId),
            .int(m.id), .int(Int64(m.date)), .int(0), .int(Int64(m.editDate)), .int(Int64(m.viewCount)),
            .optText(m.forwardedFrom), .int(m.replyTo?.messageId ?? 0),
            .int(Int64(entityCreateDate)), .text(m.body.plainText),
            .optText(mediaPath), .int(Int64(m.body.ayuDocumentType)), .optText(mime),
            encode(m).map { .blob($0) } ?? .null,
        ]
    }

    private static let baseColumns = "userId, dialogId, groupedId, peerId, fromId, topicId, messageId, date, flags, editDate, views, fwdName, replyMessageId, entityCreateDate, text, mediaPath, documentType, mimeType, payload"
    private static let basePlaceholders = Array(repeating: "?", count: 19).joined(separator: ", ")

    // MARK: - Message cache (iOS only)

    func cache(_ messages: [MessageItem], userId: Int64) {
        guard !messages.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        do {
            try db.transaction {
                for m in messages where !m.ayuDeleted {
                    guard let payload = encode(m) else { continue }
                    try db.run("INSERT OR REPLACE INTO messagecache (userId, dialogId, messageId, date, cachedAt, payload) VALUES (?, ?, ?, ?, ?, ?)",
                               [.int(userId), .int(m.chatId), .int(m.id), .int(Int64(m.date)), .int(now), .blob(payload)])
                }
            }
        } catch {
            AppLog.error("cache messages: \(error)")
        }
    }

    func cachedMessage(userId: Int64, dialogId: Int64, messageId: Int64) -> MessageItem? {
        var result: MessageItem?
        try? db.query("SELECT payload FROM messagecache WHERE userId = ? AND dialogId = ? AND messageId = ?",
                      [.int(userId), .int(dialogId), .int(messageId)]) { result = decode($0.blob(0)) }
        return result
    }

    func removeCached(userId: Int64, dialogId: Int64, messageIds: [Int64]) {
        for id in messageIds {
            _ = try? db.run("DELETE FROM messagecache WHERE userId = ? AND dialogId = ? AND messageId = ?",
                            [.int(userId), .int(dialogId), .int(id)])
        }
    }

    /// Re-keys a cached message after TDLib replaces a temporary id with the server id.
    func renameCached(userId: Int64, dialogId: Int64, oldId: Int64, message: MessageItem) {
        removeCached(userId: userId, dialogId: dialogId, messageIds: [oldId])
        cache([message], userId: userId)
    }

    func pruneCache(olderThan seconds: TimeInterval) {
        let border = Int64(Date().timeIntervalSince1970 - seconds)
        _ = try? db.run("DELETE FROM messagecache WHERE cachedAt < ?", [.int(border)])
    }

    // MARK: - Deleted messages (DeletedMessageDao)

    func deletedExists(userId: Int64, dialogId: Int64, topicId: Int64, messageId: Int64) -> Bool {
        let n = (try? db.scalarInt("SELECT EXISTS(SELECT 1 FROM deletedmessage WHERE userId = ? AND dialogId = ? AND topicId = ? AND messageId = ?)",
                                   [.int(userId), .int(dialogId), .int(topicId), .int(messageId)])) ?? 0
        return n == 1
    }

    /// Returns the generated fakeId, or nil if the message was already stored.
    @discardableResult
    func insertDeleted(userId: Int64, message: MessageItem, entityCreateDate: Int, mediaPath: String?, reactions: [ReactionItem]) -> Int64? {
        var stored = message
        stored.reactions = []
        var fakeId: Int64?
        do {
            try db.transaction {
                let changed = try db.run("INSERT OR IGNORE INTO deletedmessage (\(Self.baseColumns)) VALUES (\(Self.basePlaceholders))",
                                         baseValues(userId: userId, message: stored, entityCreateDate: entityCreateDate, mediaPath: mediaPath))
                guard changed > 0 else { return }
                let id = db.lastInsertRowId
                fakeId = id
                for r in reactions {
                    try db.run("INSERT INTO deletedmessagereaction (deletedMessageId, emoticon, documentId, isCustom, count, selfSelected) VALUES (?, ?, ?, ?, ?, ?)",
                               [.int(id), .optText(r.emoji), .int(r.customEmojiId ?? 0), .bool(r.customEmojiId != nil), .int(Int64(r.count)), .bool(r.isChosen)])
                }
            }
        } catch {
            AppLog.error("insert deleted: \(error)")
        }
        return fakeId
    }

    private func reactions(forFakeId fakeId: Int64) -> [ReactionItem] {
        var list: [ReactionItem] = []
        try? db.query("SELECT emoticon, documentId, isCustom, count, selfSelected FROM deletedmessagereaction WHERE deletedMessageId = ?", [.int(fakeId)]) { row in
            let isCustom = row.int(2) == 1
            list.append(ReactionItem(emoji: isCustom ? nil : row.text(0),
                                     customEmojiId: isCustom ? row.int(1) : nil,
                                     count: Int(row.int(3)), isChosen: row.int(4) == 1))
        }
        return list
    }

    private func readDeleted(_ sql: String, _ args: [SQLiteDatabase.Value]) -> [MessageItem] {
        var rows: [(Int64, Data?, String?)] = []
        try? db.query(sql, args) { rows.append(($0.int(0), $0.blob(1), $0.text(2))) }
        return rows.compactMap { fakeId, payload, mediaPath in
            guard var m = decode(payload) else { return nil }
            m.ayuDeleted = true
            m.reactions = reactions(forFakeId: fakeId)
            if let mediaPath, var file = m.body.mainFile {
                file.localPath = mediaPath
                m.body = m.body.replacingMainFile(file)
            }
            return m
        }
    }

    func deletedMessage(userId: Int64, dialogId: Int64, messageId: Int64) -> MessageItem? {
        readDeleted("SELECT fakeId, payload, mediaPath FROM deletedmessage WHERE userId = ? AND dialogId = ? AND messageId = ?",
                    [.int(userId), .int(dialogId), .int(messageId)]).first
    }

    /// DeletedMessageDao.getMessages — messages with startId <= id <= endId.
    func deletedMessages(userId: Int64, dialogId: Int64, startId: Int64, endId: Int64, limit: Int) -> [MessageItem] {
        readDeleted("SELECT fakeId, payload, mediaPath FROM deletedmessage WHERE userId = ? AND dialogId = ? AND ? <= messageId AND messageId <= ? ORDER BY messageId LIMIT ?",
                    [.int(userId), .int(dialogId), .int(startId), .int(endId), .int(Int64(limit))])
    }

    func deletedMessagesGrouped(userId: Int64, dialogId: Int64, groupedId: Int64) -> [MessageItem] {
        readDeleted("SELECT fakeId, payload, mediaPath FROM deletedmessage WHERE userId = ? AND dialogId = ? AND groupedId = ? ORDER BY messageId",
                    [.int(userId), .int(dialogId), .int(groupedId)])
    }

    /// Newest deleted messages of a dialog (for the "Deleted messages" screen).
    func latestDeleted(userId: Int64, dialogId: Int64, limit: Int) -> [MessageItem] {
        readDeleted("SELECT fakeId, payload, mediaPath FROM deletedmessage WHERE userId = ? AND dialogId = ? ORDER BY messageId DESC LIMIT ?",
                    [.int(userId), .int(dialogId), .int(Int64(limit))])
    }

    /// Returns the media path of the removed entry so the caller can delete the file.
    @discardableResult
    func removeDeleted(userId: Int64, dialogId: Int64, messageId: Int64) -> String? {
        var mediaPath: String?
        var fakeId: Int64?
        try? db.query("SELECT fakeId, mediaPath FROM deletedmessage WHERE userId = ? AND dialogId = ? AND messageId = ?",
                      [.int(userId), .int(dialogId), .int(messageId)]) { fakeId = $0.int(0); mediaPath = $0.text(1) }
        if let fakeId {
            _ = try? db.run("DELETE FROM deletedmessagereaction WHERE deletedMessageId = ?", [.int(fakeId)])
            _ = try? db.run("DELETE FROM deletedmessage WHERE fakeId = ?", [.int(fakeId)])
        }
        return mediaPath
    }

    // MARK: - Edit history (EditedMessageDao)

    func insertRevision(userId: Int64, message: MessageItem, entityCreateDate: Int, mediaPath: String?) {
        _ = try? db.run("INSERT INTO editedmessage (\(Self.baseColumns)) VALUES (\(Self.basePlaceholders))",
                        baseValues(userId: userId, message: message, entityCreateDate: entityCreateDate, mediaPath: mediaPath))
    }

    func revisions(userId: Int64, dialogId: Int64, messageId: Int64) -> [EditRevision] {
        var list: [EditRevision] = []
        try? db.query("SELECT fakeId, payload, mediaPath, entityCreateDate FROM editedmessage WHERE userId = ? AND dialogId = ? AND messageId = ? ORDER BY entityCreateDate",
                      [.int(userId), .int(dialogId), .int(messageId)]) { row in
            guard var m = decode(row.blob(1)) else { return }
            if let path = row.text(2), var file = m.body.mainFile {
                file.localPath = path
                m.body = m.body.replacingMainFile(file)
            }
            list.append(EditRevision(id: row.int(0), message: m, entityCreateDate: Int(row.int(3))))
        }
        return list
    }

    func lastRevisionMediaPath(userId: Int64, dialogId: Int64, messageId: Int64) -> String?? {
        var result: String??
        try? db.query("SELECT mediaPath FROM editedmessage WHERE userId = ? AND dialogId = ? AND messageId = ? ORDER BY entityCreateDate DESC LIMIT 1",
                      [.int(userId), .int(dialogId), .int(messageId)]) { result = .some($0.text(0)) }
        return result
    }

    /// EditedMessageDao.updateAttachmentForRevisionsBetweenDates
    func updateRevisionAttachment(userId: Int64, dialogId: Int64, messageId: Int64, oldPath: String, newPath: String) {
        _ = try? db.run("UPDATE editedmessage SET mediaPath = ? WHERE userId = ? AND dialogId = ? AND messageId = ? AND mediaPath = ?",
                        [.text(newPath), .int(userId), .int(dialogId), .int(messageId), .text(oldPath)])
    }

    /// Ids among `messageIds` that have at least one stored revision (EditedMessageDao.hasAnyRevisions, batched).
    func messagesWithRevisions(userId: Int64, dialogId: Int64, messageIds: [Int64]) -> Set<Int64> {
        guard !messageIds.isEmpty else { return [] }
        var result = Set<Int64>()
        for chunk in stride(from: 0, to: messageIds.count, by: 500).map({ Array(messageIds[$0..<min($0 + 500, messageIds.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try? db.query("SELECT DISTINCT messageId FROM editedmessage WHERE userId = ? AND dialogId = ? AND messageId IN (\(placeholders))",
                          [.int(userId), .int(dialogId)] + chunk.map { .int($0) }) { result.insert($0.int(0)) }
        }
        return result
    }

    // MARK: - Maintenance

    struct Stats {
        var deleted: Int
        var revisions: Int
        var cached: Int
    }

    func stats() -> Stats {
        Stats(deleted: Int((try? db.scalarInt("SELECT COUNT(*) FROM deletedmessage")) ?? 0),
              revisions: Int((try? db.scalarInt("SELECT COUNT(*) FROM editedmessage")) ?? 0),
              cached: Int((try? db.scalarInt("SELECT COUNT(*) FROM messagecache")) ?? 0))
    }

    /// AyuData.clean(): wipes saved deleted messages, edit history and the message cache.
    func clean() {
        do {
            try db.transaction {
                try db.execute("DELETE FROM deletedmessagereaction; DELETE FROM deletedmessage; DELETE FROM editedmessage; DELETE FROM messagecache;")
            }
            try db.execute("VACUUM;")
        } catch {
            AppLog.error("clean: \(error)")
        }
    }
}
