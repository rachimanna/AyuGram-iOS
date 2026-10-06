import Foundation
import TDLibKit

// Converts TDLib models into the app's own UI/storage models.
// Views never import TDLibKit (its `Text`, `Animation`, `Error` … would clash with SwiftUI/Swift).

extension FileRef {
    init(_ f: File) {
        self.init(id: f.id,
                  size: f.size > 0 ? f.size : f.expectedSize,
                  localPath: f.local.isDownloadingCompleted && !f.local.path.isEmpty ? f.local.path : nil,
                  uniqueId: f.remote.uniqueId.isEmpty ? nil : f.remote.uniqueId)
    }
}

extension ThumbRef {
    init?(mini: Minithumbnail?, thumb: Thumbnail?) {
        guard mini != nil || thumb != nil else { return nil }
        self.init(minithumbnail: mini?.data,
                  file: thumb.map { FileRef($0.file) },
                  width: thumb?.width ?? mini?.width ?? 0,
                  height: thumb?.height ?? mini?.height ?? 0)
    }
}

extension RichText {
    init(_ ft: FormattedText) {
        self.init(text: ft.text, entities: ft.entities.compactMap(TextEntityItem.init))
    }
}

extension TextEntityItem {
    init?(_ e: TextEntity) {
        let kind: EntityKind
        switch e.type {
        case .textEntityTypeBold: kind = .bold
        case .textEntityTypeItalic: kind = .italic
        case .textEntityTypeUnderline: kind = .underline
        case .textEntityTypeStrikethrough: kind = .strikethrough
        case .textEntityTypeSpoiler: kind = .spoiler
        case .textEntityTypeCode: kind = .code
        case .textEntityTypePre: kind = .pre(language: "")
        case .textEntityTypePreCode(let p): kind = .pre(language: p.language)
        case .textEntityTypeUrl: kind = .url
        case .textEntityTypeTextUrl(let u): kind = .textUrl(u.url)
        case .textEntityTypeMention: kind = .mention
        case .textEntityTypeMentionName(let m): kind = .mentionName(userId: m.userId)
        case .textEntityTypeHashtag: kind = .hashtag
        case .textEntityTypeCashtag: kind = .cashtag
        case .textEntityTypeEmailAddress: kind = .email
        case .textEntityTypePhoneNumber: kind = .phone
        case .textEntityTypeBotCommand: kind = .botCommand
        case .textEntityTypeBlockQuote, .textEntityTypeExpandableBlockQuote: kind = .blockQuote
        case .textEntityTypeCustomEmoji(let c): kind = .customEmoji(id: c.customEmojiId.rawValue)
        default: return nil
        }
        self.init(offset: e.offset, length: e.length, kind: kind)
    }

    var tdEntity: TextEntity? {
        let type: TextEntityType
        switch kind {
        case .bold: type = .textEntityTypeBold
        case .italic: type = .textEntityTypeItalic
        case .underline: type = .textEntityTypeUnderline
        case .strikethrough: type = .textEntityTypeStrikethrough
        case .spoiler: type = .textEntityTypeSpoiler
        case .code: type = .textEntityTypeCode
        case .pre(let lang): type = lang.isEmpty ? .textEntityTypePre : .textEntityTypePreCode(TextEntityTypePreCode(language: lang))
        case .textUrl(let url): type = .textEntityTypeTextUrl(TextEntityTypeTextUrl(url: url))
        case .mentionName(let id): type = .textEntityTypeMentionName(TextEntityTypeMentionName(userId: id))
        case .blockQuote: type = .textEntityTypeBlockQuote
        default: return nil // auto-detected by the server
        }
        return TextEntity(length: length, offset: offset, type: type)
    }
}

extension RichText {
    var formattedText: FormattedText {
        FormattedText(entities: entities.compactMap(\.tdEntity), text: text)
    }
}

extension SenderRef {
    init(_ s: MessageSender) {
        switch s {
        case .messageSenderUser(let u): self = .user(u.userId)
        case .messageSenderChat(let c): self = .chat(c.chatId)
        }
    }
}

extension PhotoRef {
    init(_ p: ChatPhotoInfo) {
        self.init(small: FileRef(p.small), big: FileRef(p.big), minithumbnail: p.minithumbnail?.data)
    }

    init(_ p: ProfilePhoto) {
        self.init(small: FileRef(p.small), big: FileRef(p.big), minithumbnail: p.minithumbnail?.data)
    }
}

extension ReactionItem {
    init(_ r: MessageReaction) {
        switch r.type {
        case .reactionTypeEmoji(let e):
            self.init(emoji: e.emoji, customEmojiId: nil, count: r.totalCount, isChosen: r.isChosen)
        case .reactionTypeCustomEmoji(let c):
            self.init(emoji: nil, customEmojiId: c.customEmojiId.rawValue, count: r.totalCount, isChosen: r.isChosen)
        case .reactionTypePaid:
            self.init(emoji: "⭐️", customEmojiId: nil, count: r.totalCount, isChosen: r.isChosen, isPaid: true)
        }
    }
}

@MainActor
enum TDConvert {
    /// Resolves user/chat names for service messages and forward headers.
    typealias NameResolver = @MainActor (SenderRef) -> String

    static func message(_ m: Message, names: NameResolver) -> MessageItem {
        var item = MessageItem(id: m.id,
                               chatId: m.chatId,
                               sender: SenderRef(m.senderId),
                               isOutgoing: m.isOutgoing,
                               date: m.date,
                               editDate: m.editDate,
                               body: body(m.content, sender: SenderRef(m.senderId), names: names))
        if case .messageReplyToMessage(let r)? = m.replyTo {
            item.replyTo = ReplyInfo(chatId: r.chatId == 0 ? m.chatId : r.chatId, messageId: r.messageId,
                                     quote: r.quote?.text.text)
        }
        if let f = m.forwardInfo {
            item.forwardedFrom = forwardName(f.origin, names: names)
        }
        item.inlineKeyboard = inlineKeyboard(m.replyMarkup)
        item.authorSignature = m.authorSignature
        item.viaBotUserId = m.viaBotUserId
        item.mediaAlbumId = m.mediaAlbumId.rawValue
        item.isChannelPost = m.isChannelPost
        item.isPinned = m.isPinned
        item.selfDestructIn = m.selfDestructIn
        if let info = m.interactionInfo {
            item.viewCount = info.viewCount
            item.replyCount = info.replyInfo?.replyCount ?? 0
            item.reactions = info.reactions?.reactions.map(ReactionItem.init) ?? []
        }
        switch m.sendingState {
        case .messageSendingStatePending?: item.sendingState = .pending
        case .messageSendingStateFailed(let f)?: item.sendingState = .failed(f.error.message)
        case nil: item.sendingState = .sent
        }
        if m.schedulingState != nil { item.isScheduled = true }
        if case .messageTopicForum(let t)? = m.topicId { item.topicId = Int64(t.forumTopicId) }
        return item
    }

    static func inlineKeyboard(_ markup: ReplyMarkup?) -> [[BotButtonItem]]? {
        guard case .replyMarkupInlineKeyboard(let keyboard)? = markup else { return nil }
        return keyboard.rows.map { row in
            row.map { button in
                let action: BotButtonItem.Action
                switch button.type {
                case .inlineKeyboardButtonTypeUrl(let value): action = .url(value.url)
                case .inlineKeyboardButtonTypeCallback(let value): action = .callback(value.data)
                case .inlineKeyboardButtonTypeCopyText(let value): action = .copy(value.text)
                case .inlineKeyboardButtonTypeUser(let value): action = .user(value.userId)
                default: action = .unsupported
                }
                return BotButtonItem(text: button.text, action: action)
            }
        }
    }

    static func replyKeyboard(_ message: Message) -> BotReplyKeyboard? {
        guard case .replyMarkupShowKeyboard(let keyboard)? = message.replyMarkup else { return nil }
        let rows = keyboard.rows.map { row in
            row.map { button in
                BotButtonItem(text: button.text, action: button.type == .keyboardButtonTypeText ? .text : .unsupported)
            }
        }
        return BotReplyKeyboard(messageId: message.id, rows: rows, oneTime: keyboard.oneTime, forceReply: keyboard.forceReply)
    }

    static func reactions(_ info: MessageInteractionInfo?) -> [ReactionItem] {
        info?.reactions?.reactions.map(ReactionItem.init) ?? []
    }

    static func forwardName(_ origin: MessageOrigin, names: NameResolver) -> String {
        switch origin {
        case .messageOriginUser(let u): return names(.user(u.senderUserId))
        case .messageOriginHiddenUser(let h): return h.senderName
        case .messageOriginChat(let c): return names(.chat(c.senderChatId))
        case .messageOriginChannel(let c):
            let name = names(.chat(c.chatId))
            return c.authorSignature.isEmpty ? name : "\(name) (\(c.authorSignature))"
        }
    }

    static func largestPhoto(_ p: Photo) -> PhotoItem? {
        guard let best = p.sizes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let small = p.sizes.min(by: { $0.width * $0.height < $1.width * $1.height })
        let thumb = ThumbRef(minithumbnail: p.minithumbnail?.data,
                             file: small.map { FileRef($0.photo) },
                             width: small?.width ?? 0, height: small?.height ?? 0)
        return PhotoItem(thumb: thumb, file: FileRef(best.photo), width: best.width, height: best.height)
    }

    static func body(_ c: MessageContent, sender: SenderRef, names: NameResolver) -> MessageBody {
        let who = names(sender)
        switch c {
        case .messageText(let t):
            return .text(RichText(t.text))
        case .messagePhoto(let p):
            guard let photo = largestPhoto(p.photo) else { return .unsupported(L("AttachPhoto")) }
            return .photo(photo, caption: RichText(p.caption))
        case .messageVideo(let v):
            return .video(video(v.video), caption: RichText(v.caption))
        case .messageAnimation(let a):
            let an = a.animation
            return .animation(VideoItem(thumb: ThumbRef(mini: an.minithumbnail, thumb: an.thumbnail), file: FileRef(an.animation),
                                        width: an.width, height: an.height, duration: an.duration, fileName: an.fileName),
                              caption: RichText(a.caption))
        case .messageVideoNote(let n):
            let vn = n.videoNote
            return .videoNote(VideoItem(thumb: ThumbRef(mini: vn.minithumbnail, thumb: vn.thumbnail), file: FileRef(vn.video),
                                        width: vn.length, height: vn.length, duration: vn.duration, fileName: "", isRound: true))
        case .messageSticker(let s):
            return .sticker(sticker(s.sticker))
        case .messageDocument(let d):
            let doc = d.document
            return .document(DocumentItem(fileName: doc.fileName, mimeType: doc.mimeType, file: FileRef(doc.document),
                                          thumb: ThumbRef(mini: doc.minithumbnail, thumb: doc.thumbnail)),
                             caption: RichText(d.caption))
        case .messageAudio(let a):
            let au = a.audio
            return .audio(AudioItem(title: au.title.isEmpty ? au.fileName : au.title, performer: au.performer,
                                    duration: au.duration, file: FileRef(au.audio), mimeType: au.mimeType,
                                    waveform: nil, isVoice: false),
                          caption: RichText(a.caption))
        case .messageVoiceNote(let v):
            let vn = v.voiceNote
            return .audio(AudioItem(title: L("AttachAudio"), performer: "", duration: vn.duration, file: FileRef(vn.voice),
                                    mimeType: vn.mimeType, waveform: vn.waveform, isVoice: true),
                          caption: RichText(v.caption))
        case .messageLocation(let l):
            return .location(latitude: l.location.latitude, longitude: l.location.longitude)
        case .messageVenue(let v):
            return .location(latitude: v.venue.location.latitude, longitude: v.venue.location.longitude)
        case .messageContact(let c):
            return .contact(name: "\(c.contact.firstName) \(c.contact.lastName)".trimmingCharacters(in: .whitespaces),
                            phone: c.contact.phoneNumber)
        case .messagePoll(let p):
            return .poll(poll(p.poll))
        case .messageAnimatedEmoji(let e):
            return .animatedEmoji(e.emoji)
        case .messageDice(let d):
            return .dice(emoji: d.emoji, value: d.value)
        case .messageCall(let call):
            return .call(isVideo: call.isVideo, duration: call.duration)
        case .messageExpiredPhoto: return .expired(L("AttachPhotoExpired"))
        case .messageExpiredVideo: return .expired(L("AttachVideoExpired"))
        case .messageExpiredVideoNote: return .expired(L("AttachVideoExpired"))
        case .messageExpiredVoiceNote: return .expired(L("AttachAudioExpired"))

        // Service messages
        case .messageBasicGroupChatCreate(let g): return .service(LF("ServiceCreatedGroup", who, g.title))
        case .messageSupergroupChatCreate(let g): return .service(LF("ServiceCreatedGroup", who, g.title))
        case .messageChatChangeTitle(let t): return .service(LF("ServiceChangedTitle", who, t.title))
        case .messageChatChangePhoto: return .service(LF("ServiceChangedPhoto", who))
        case .messageChatDeletePhoto: return .service(LF("ServiceRemovedPhoto", who))
        case .messageChatAddMembers(let a):
            let added = a.memberUserIds.map { names(.user($0)) }.joined(separator: ", ")
            if a.memberUserIds == [sender.id] { return .service(LF("ServiceJoined", who)) }
            return .service(LF("ServiceAddedMembers", who, added))
        case .messageChatJoinByLink, .messageChatJoinByRequest: return .service(LF("ServiceJoined", who))
        case .messageChatDeleteMember(let d):
            if d.userId == sender.id { return .service(LF("ServiceLeft", who)) }
            return .service(LF("ServiceRemovedMember", who, names(.user(d.userId))))
        case .messagePinMessage: return .service(LF("ServicePinned", who))
        case .messageScreenshotTaken: return .service(LF("ServiceScreenshot", who))
        case .messageChatSetMessageAutoDeleteTime(let t):
            return .service(t.messageAutoDeleteTime == 0 ? LF("ServiceAutoDeleteOff", who) : LF("ServiceAutoDeleteOn", who, Formatters.duration(t.messageAutoDeleteTime)))
        case .messageChatUpgradeTo, .messageChatUpgradeFrom: return .service(L("ServiceUpgraded"))
        case .messageForumTopicCreated(let t): return .service(LF("ServiceTopicCreated", t.name))
        case .messageContactRegistered: return .service(LF("ServiceContactJoined", who))
        case .messageGameScore(let g): return .service(LF("ServiceGameScore", who, g.score))
        case .messageCustomServiceAction(let a): return .service(a.text)
        case .messageVideoChatStarted: return .service(L("ServiceVideoChatStarted"))
        case .messageVideoChatEnded(let e): return .service(LF("ServiceVideoChatEnded", Formatters.duration(e.duration)))
        case .messageGift: return .service(L("ServiceGift"))
        case .messageGiftedPremium: return .service(L("ServiceGiftPremium"))
        case .messageStory: return .unsupported(L("AttachStory"))
        case .messageGame: return .unsupported(L("AttachGame"))
        case .messageInvoice: return .unsupported(L("AttachInvoice"))
        case .messageUnsupported: return .unsupported(L("UnsupportedMessage"))
        default:
            return .unsupported(L("UnsupportedMessage"))
        }
    }

    static func video(_ v: Video) -> VideoItem {
        VideoItem(thumb: ThumbRef(mini: v.minithumbnail, thumb: v.thumbnail), file: FileRef(v.video),
                  width: v.width, height: v.height, duration: v.duration, fileName: v.fileName)
    }

    static func poll(_ value: Poll) -> PollItem {
        var isQuiz = false
        if case .pollTypeQuiz = value.type { isQuiz = true }
        return PollItem(question: value.question.text,
            options: value.options.map { .init(text: $0.text.text, votePercentage: $0.votePercentage, isChosen: $0.isChosen) },
            totalVoters: value.totalVoterCount, isQuiz: isQuiz, isClosed: value.isClosed,
            allowsMultipleAnswers: value.allowsMultipleAnswers, canVote: value.voteRestrictionReason == nil,
            pollId: value.id.rawValue, canSeeResults: value.canSeeResults)
    }

    static func sticker(_ s: Sticker) -> StickerItem {
        let format: StickerItem.Format
        switch s.format {
        case .stickerFormatWebp: format = .webp
        case .stickerFormatTgs: format = .tgs
        case .stickerFormatWebm: format = .webm
        }
        return StickerItem(emoji: s.emoji, format: format, file: FileRef(s.sticker),
                           thumb: ThumbRef(mini: nil, thumb: s.thumbnail), width: s.width, height: s.height)
    }

    static func presence(_ s: UserStatus) -> UserPresence {
        switch s {
        case .userStatusEmpty: return .longTimeAgo
        case .userStatusOnline(let o): return .online(expires: o.expires)
        case .userStatusOffline(let o): return .offline(wasOnline: o.wasOnline)
        case .userStatusRecently: return .recently
        case .userStatusLastWeek: return .lastWeek
        case .userStatusLastMonth: return .lastMonth
        }
    }

    static func user(_ u: User) -> UserItem {
        var isBot = false
        var isDeleted = false
        switch u.type {
        case .userTypeBot: isBot = true
        case .userTypeDeleted: isDeleted = true
        default: break
        }
        return UserItem(id: u.id, firstName: u.firstName, lastName: u.lastName,
                        usernames: u.usernames?.activeUsernames ?? [],
                        phoneNumber: u.phoneNumber,
                        photo: u.profilePhoto.map(PhotoRef.init),
                        status: isBot ? .bot : presence(u.status),
                        isBot: isBot, isPremium: u.isPremium,
                        isVerified: u.verificationStatus?.isVerified ?? false,
                        isContact: u.isContact, isDeleted: isDeleted,
                        accentColorId: u.accentColorId)
    }

    static func chatListKey(_ list: ChatList) -> ChatListKey {
        switch list {
        case .chatListMain: return .main
        case .chatListArchive: return .archive
        case .chatListFolder(let f): return .folder(f.chatFolderId)
        }
    }

    static func tdChatList(_ key: ChatListKey) -> ChatList {
        switch key {
        case .main: return .chatListMain
        case .archive: return .chatListArchive
        case .folder(let id): return .chatListFolder(ChatListFolder(chatFolderId: id))
        }
    }

    static func draftText(_ d: DraftMessage?) -> String? {
        guard let d, case .draftMessageContentText(let t) = d.content, !t.text.text.isEmpty else { return nil }
        return t.text.text
    }
}
