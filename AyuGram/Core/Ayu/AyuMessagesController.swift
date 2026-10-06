/*
 * Port of AyuMessagesController.java + AyuSavePreferences.java (Copyright @Radolyn, 2023, GPL-2.0).
 *
 * Android flow: MessagesController intercepts updateDeleteMessages / updateEditMessage, reads the
 * old message from Telegram's local storage and stores it in Room.
 * iOS flow: TelegramService forwards TDLib updates here. Every message seen is first written to
 * `messagecache`, so on updateDeleteMessages (is_permanent) / updateMessageContent the previous
 * version is still available.
 */

import Foundation

/// What AyuGram needs to know about the dialog a message belongs to.
struct AyuDialogContext {
    var isBot: Bool
    var kind: AyuDialogKind
}

final class AyuMessagesController {
    static let shared = AyuMessagesController()

    private let queue = DispatchQueue(label: "com.ayugram.port.ayu-db", qos: .utility)
    private var database: AyuDatabase?
    private let config: AyuConfig

    /// Telegram user id of the logged-in account (AyuSavePreferences.userId).
    private var _userId: Int64 = 0
    var userId: Int64 {
        get { queue.sync { _userId } }
        set { queue.async { self._userId = newValue } }
    }

    /// Resolves a TDLib file id to a local path if the file is fully downloaded.
    var fileResolver: (@MainActor (Int) async -> String?)?

    /// Messages older than this are dropped from the cache (deleted/edited history is kept forever).
    var cacheRetention: TimeInterval = 90 * 24 * 3600

    init(config: AyuConfig = .shared, databasePath: String? = nil) {
        self.config = config
        let path = databasePath ?? AyuDatabase.defaultPath()
        let journal = config.sqliteJournalMode
        queue.async {
            do {
                self.database = try AyuDatabase(path: path, journalMode: journal)
                self.database?.pruneCache(olderThan: self.cacheRetention)
            } catch {
                AppLog.error("Cannot open AyuGram database: \(error)")
            }
            Self.initializeAttachmentsFolder()
        }
    }

    private static func initializeAttachmentsFolder() {
        try? FileManager.default.createDirectory(at: AyuConstants.attachmentsDirectory, withIntermediateDirectories: true)
    }

    /// Waits until all queued database work is done (used by tests).
    func sync() { queue.sync {} }

    // MARK: - Cache

    func onMessagesSeen(_ messages: [MessageItem]) {
        let real = messages.filter { !$0.ayuDeleted && !$0.isScheduled && $0.id > 0 }
        guard !real.isEmpty else { return }
        queue.async {
            guard self._userId != 0 else { return }
            self.database?.cache(real, userId: self._userId)
        }
    }

    func onMessageSendSucceeded(oldId: Int64, message: MessageItem) {
        queue.async {
            guard self._userId != 0 else { return }
            self.database?.renameCached(userId: self._userId, dialogId: message.chatId, oldId: oldId, message: message)
        }
    }

    /// updateMessageEdited only carries editDate; keep the cached copy in sync.
    func onMessageEditDateChanged(chatId: Int64, messageId: Int64, editDate: Int) {
        queue.async {
            guard let db = self.database, var cached = db.cachedMessage(userId: self._userId, dialogId: chatId, messageId: messageId) else { return }
            cached.editDate = editDate
            db.cache([cached], userId: self._userId)
        }
    }

    // MARK: - Edits (onMessageEdited)

    func onMessageContentChanged(chatId: Int64, messageId: Int64, newBody: MessageBody, context: AyuDialogContext) {
        let saveHistory = config.saveEditedMessage(isBotDialog: context.isBot)
        let saveFormatting = config.saveFormatting
        let saveMediaHere = config.saveMedia(for: context.kind)
        queue.async {
            guard let db = self.database, self._userId != 0 else { return }
            let userId = self._userId
            guard let old = db.cachedMessage(userId: userId, dialogId: chatId, messageId: messageId) else { return }

            var updated = old
            updated.body = newBody
            defer { db.cache([updated], userId: userId) }

            guard saveHistory else { return }

            let oldFile = old.body.mainFile
            let newFile = newBody.mainFile
            let sameMedia: Bool
            if let o = oldFile, let n = newFile {
                sameMedia = (o.uniqueId != nil && o.uniqueId == n.uniqueId) || o.id == n.id
            } else {
                sameMedia = (oldFile == nil) == (newFile == nil)
            }
            if sameMedia && old.body.plainText == newBody.plainText && old.body.richText == newBody.richText {
                return
            }

            var revision = old
            if !saveFormatting { revision.body = revision.body.withoutFormatting() }
            let entityCreateDate = Int(Date().timeIntervalSince1970)

            if !sameMedia, saveMediaHere, let oldFile {
                // The previous media is about to disappear from the message — keep a copy.
                self.resolveAndCopy(file: oldFile, chatId: chatId, messageId: messageId, suffix: "rev\(entityCreateDate)") { path in
                    db.insertRevision(userId: userId, message: revision, entityCreateDate: entityCreateDate, mediaPath: path)
                    self.postEdited(chatId: chatId, messageId: messageId)
                }
            } else {
                db.insertRevision(userId: userId, message: revision, entityCreateDate: entityCreateDate, mediaPath: nil)
                self.postEdited(chatId: chatId, messageId: messageId)
            }
        }
    }

    private func postEdited(chatId: Int64, messageId: Int64) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ayuMessageEdited, object: nil,
                                            userInfo: ["chatId": chatId, "messageId": messageId])
        }
    }

    // MARK: - Deletions (onMessageDeleted)

    /// Handles updateDeleteMessages(is_permanent = true, from_cache = false).
    /// `completion` runs on the main queue with the messages that were saved (marked ayuDeleted).
    func onMessagesDeleted(chatId: Int64, messageIds: [Int64], context: AyuDialogContext,
                           completion: @escaping ([MessageItem]) -> Void) {
        let save = config.saveDeletedMessage(isBotDialog: context.isBot)
        let saveMediaHere = config.saveMedia(for: context.kind)
        let saveReactions = config.saveReactions
        let saveFormatting = config.saveFormatting
        let permitted = Set(messageIds.filter { AyuState.shared.isDeletePermitted(chatId: chatId, messageId: $0) })
        permitted.forEach { AyuState.shared.messageDeleted(chatId: chatId, messageId: $0) }

        queue.async {
            guard let db = self.database, self._userId != 0 else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let userId = self._userId
            var toSave: [MessageItem] = []
            for id in messageIds {
                defer { db.removeCached(userId: userId, dialogId: chatId, messageIds: [id]) }
                guard save, !permitted.contains(id),
                      var msg = db.cachedMessage(userId: userId, dialogId: chatId, messageId: id),
                      !db.deletedExists(userId: userId, dialogId: chatId, topicId: msg.topicId, messageId: id)
                else { continue }
                if !saveFormatting { msg.body = msg.body.withoutFormatting() }
                if !saveReactions { msg.reactions = [] }
                toSave.append(msg)
            }
            guard !toSave.isEmpty else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let group = DispatchGroup()
            var saved: [MessageItem] = []
            let entityCreateDate = Int(Date().timeIntervalSince1970)
            for msg in toSave {
                group.enter()
                let finish: (String?) -> Void = { path in
                    db.insertDeleted(userId: userId, message: msg, entityCreateDate: entityCreateDate,
                                     mediaPath: path, reactions: msg.reactions)
                    var shown = msg
                    shown.ayuDeleted = true
                    if let path, var file = shown.body.mainFile {
                        file.localPath = path
                        shown.body = shown.body.replacingMainFile(file)
                    }
                    saved.append(shown)
                    group.leave()
                }
                if saveMediaHere, let file = msg.body.mainFile {
                    self.resolveAndCopy(file: file, chatId: chatId, messageId: msg.id, suffix: nil, then: finish)
                } else {
                    finish(nil)
                }
            }
            group.notify(queue: .main) {
                NotificationCenter.default.post(name: .ayuMessagesDeleted, object: nil,
                                                userInfo: ["chatId": chatId, "messageIds": saved.map(\.id)])
                completion(saved)
            }
        }
    }

    /// Copies a downloaded TDLib file into Documents/Saved Attachments. `then` runs on the db queue.
    private func resolveAndCopy(file: FileRef, chatId: Int64, messageId: Int64, suffix: String?, then: @escaping (String?) -> Void) {
        let resolver = fileResolver
        Task.detached(priority: .utility) {
            var source = file.localPath
            if source == nil || !(FileManager.default.fileExists(atPath: source!)) {
                source = await resolver?(file.id)
            }
            let copied: String? = {
                guard let source, FileManager.default.fileExists(atPath: source) else { return nil }
                return Self.copyAttachment(from: source, chatId: chatId, messageId: messageId, suffix: suffix)
            }()
            self.queue.async { then(copied) }
        }
    }

    static func copyAttachment(from source: String, chatId: Int64, messageId: Int64, suffix: String?) -> String? {
        let fm = FileManager.default
        let dir = AyuConstants.attachmentsDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: source)
        var name = "\(chatId)_\(messageId)"
        if let suffix { name += "_\(suffix)" }
        name += "_" + src.lastPathComponent
        let dst = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dst.path) { return dst.path }
        do {
            try fm.copyItem(at: src, to: dst)
            return dst.path
        } catch {
            AppLog.error("copy attachment failed: \(error)")
            return nil
        }
    }

    // MARK: - Queries (completion on main)

    func revisions(chatId: Int64, messageId: Int64, completion: @escaping ([EditRevision]) -> Void) {
        queue.async {
            let list = self.database?.revisions(userId: self._userId, dialogId: chatId, messageId: messageId) ?? []
            DispatchQueue.main.async { completion(list) }
        }
    }

    func messagesWithRevisions(chatId: Int64, messageIds: [Int64], completion: @escaping (Set<Int64>) -> Void) {
        queue.async {
            let set = self.database?.messagesWithRevisions(userId: self._userId, dialogId: chatId, messageIds: messageIds) ?? []
            DispatchQueue.main.async { completion(set) }
        }
    }

    func deletedMessages(chatId: Int64, startId: Int64, endId: Int64, limit: Int, completion: @escaping ([MessageItem]) -> Void) {
        queue.async {
            let list = self.database?.deletedMessages(userId: self._userId, dialogId: chatId, startId: startId, endId: endId, limit: limit) ?? []
            DispatchQueue.main.async { completion(list) }
        }
    }

    func latestDeleted(chatId: Int64, limit: Int, completion: @escaping ([MessageItem]) -> Void) {
        queue.async {
            let list = self.database?.latestDeleted(userId: self._userId, dialogId: chatId, limit: limit) ?? []
            DispatchQueue.main.async { completion(list) }
        }
    }

    func cachedIncoming(chatId: Int64, messageId: Int64, completion: @escaping (Bool) -> Void) {
        queue.async {
            let incoming = self.database?.cachedMessage(userId: self._userId, dialogId: chatId, messageId: messageId).map { !$0.isOutgoing } ?? false
            DispatchQueue.main.async { completion(incoming) }
        }
    }
    func allDeleted(limit: Int, offset: Int, completion: @escaping ([MessageItem]) -> Void) {
        queue.async {
            let list = self.database?.allDeleted(userId: self._userId, limit: limit, offset: offset) ?? []
            DispatchQueue.main.async { completion(list) }
        }
    }
    func historyArchive(completion: @escaping ([MessageItem], [EditRevision]) -> Void) {
        queue.async {
            let deleted = self.database?.allDeleted(userId: self._userId, limit: Int.max, offset: 0) ?? []
            let edits = self.database?.allRevisions(userId: self._userId) ?? []
            DispatchQueue.main.async { completion(deleted, edits) }
        }
    }
    private var mediaBeingPreserved: Set<String> = [] // accessed only on the database queue
    func preserveViewedMedia(_ message: MessageItem, localPath: String) {
        queue.async {
            let account = self._userId
            let key = "\(account):\(message.chatId):\(message.id)"
            guard account != 0, !self.mediaBeingPreserved.contains(key), let db = self.database else { return }
            self.mediaBeingPreserved.insert(key)
            guard let path = Self.copyAttachment(from: localPath, chatId: message.chatId, messageId: message.id, suffix: "viewed_\(account)") else {
                self.mediaBeingPreserved.remove(key); return
            }
            db.retainMedia(userId: account, message: message, path: path)
            DispatchQueue.main.async { NotificationCenter.default.post(name: .ayuHistoryChanged, object: nil) }
        }
    }
    func retainedMedia(completion: @escaping ([MessageItem]) -> Void) {
        queue.async {
            let list = self.database?.retainedMedia(userId: self._userId) ?? []
            DispatchQueue.main.async { completion(list) }
        }
    }

    /// AyuMessagesController.delete — removes a saved deleted message and its copied attachment.
    func removeSavedDeleted(chatId: Int64, messageId: Int64) {
        queue.async {
            guard let path = self.database?.removeDeleted(userId: self._userId, dialogId: chatId, messageId: messageId) else { return }
            if path.contains(AyuConstants.attachmentsSubfolder) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    func stats(completion: @escaping (AyuDatabase.Stats) -> Void) {
        queue.async {
            let s = self.database?.stats() ?? .init(deleted: 0, revisions: 0, cached: 0)
            DispatchQueue.main.async { completion(s) }
        }
    }

    /// "Clear Ayu Database": wipes the database and the Saved Attachments folder.
    func clean(completion: @escaping () -> Void) {
        queue.async {
            self.database?.clean()
            self.mediaBeingPreserved = []
            try? FileManager.default.removeItem(at: AyuConstants.attachmentsDirectory)
            Self.initializeAttachmentsFolder()
            DispatchQueue.main.async { completion() }
        }
    }
}
