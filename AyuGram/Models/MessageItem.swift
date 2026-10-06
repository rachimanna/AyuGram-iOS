import Foundation

/// A file known to TDLib. `localPath` is set once the file is fully downloaded (or for
/// AyuGram-saved attachments of deleted messages, which live outside TDLib).
struct FileRef: Codable, Hashable {
    var id: Int
    var size: Int64
    var localPath: String?
    var uniqueId: String?

    var isLocal: Bool {
        guard let localPath, !localPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: localPath)
    }
}

struct ThumbRef: Codable, Hashable {
    var minithumbnail: Data?
    var file: FileRef?
    var width: Int
    var height: Int
}

enum EntityKind: Codable, Hashable {
    case bold, italic, underline, strikethrough, spoiler, code, pre(language: String)
    case url, textUrl(String), mention, mentionName(userId: Int64), hashtag, cashtag
    case email, phone, botCommand, blockQuote, customEmoji(id: Int64)
}

struct TextEntityItem: Codable, Hashable {
    /// UTF-16 offset/length, exactly as TDLib reports them.
    var offset: Int
    var length: Int
    var kind: EntityKind
}

struct RichText: Codable, Hashable {
    var text: String
    var entities: [TextEntityItem] = []

    static let empty = RichText(text: "")
    var isEmpty: Bool { text.isEmpty }
}

struct PhotoItem: Codable, Hashable {
    var thumb: ThumbRef?
    /// Largest size available.
    var file: FileRef
    var width: Int
    var height: Int
}

struct VideoItem: Codable, Hashable {
    var thumb: ThumbRef?
    var file: FileRef
    var width: Int
    var height: Int
    var duration: Int
    var fileName: String
    var isRound: Bool = false
}

struct StickerItem: Codable, Hashable {
    enum Format: String, Codable { case webp, tgs, webm }
    var emoji: String
    var format: Format
    var file: FileRef
    var thumb: ThumbRef?
    var width: Int
    var height: Int
}

struct DocumentItem: Codable, Hashable {
    var fileName: String
    var mimeType: String
    var file: FileRef
    var thumb: ThumbRef?
}

struct AudioItem: Codable, Hashable {
    var title: String
    var performer: String
    var duration: Int
    var file: FileRef
    var mimeType: String
    /// 5-bit packed waveform for voice notes (TDLib format), nil for music.
    var waveform: Data?
    var isVoice: Bool
}

struct PollItem: Codable, Hashable {
    struct Option: Codable, Hashable {
        var text: String
        var votePercentage: Int
        var isChosen: Bool
    }
    var question: String
    var options: [Option]
    var totalVoters: Int
    var isQuiz: Bool
    var isClosed: Bool
}

enum MessageBody: Codable, Hashable {
    case text(RichText)
    case photo(PhotoItem, caption: RichText)
    case video(VideoItem, caption: RichText)
    case animation(VideoItem, caption: RichText)
    case videoNote(VideoItem)
    case sticker(StickerItem)
    case document(DocumentItem, caption: RichText)
    case audio(AudioItem, caption: RichText)
    case location(latitude: Double, longitude: Double)
    case contact(name: String, phone: String)
    case poll(PollItem)
    case animatedEmoji(String)
    case dice(emoji: String, value: Int)
    case call(isVideo: Bool, duration: Int)
    case expired(String)
    case service(String)
    case unsupported(String)

    /// Plain text used for previews, search and the regex filters (ChatUtils.getMessageText).
    var plainText: String {
        switch self {
        case .text(let t): return t.text
        case .photo(_, let c), .video(_, let c), .animation(_, let c), .document(_, let c), .audio(_, let c): return c.text
        case .poll(let p): return p.question
        case .animatedEmoji(let e): return e
        case .contact(let name, let phone): return "\(name) \(phone)"
        default: return ""
        }
    }

    var richText: RichText? {
        switch self {
        case .text(let t): return t
        case .photo(_, let c), .video(_, let c), .animation(_, let c), .document(_, let c), .audio(_, let c):
            return c.isEmpty ? nil : c
        default: return nil
        }
    }

    /// The main downloadable file of this message, if any.
    var mainFile: FileRef? {
        switch self {
        case .photo(let p, _): return p.file
        case .video(let v, _), .animation(let v, _), .videoNote(let v): return v.file
        case .sticker(let s): return s.file
        case .document(let d, _): return d.file
        case .audio(let a, _): return a.file
        default: return nil
        }
    }

    /// AyuConstants.DOCUMENT_TYPE_*
    var ayuDocumentType: Int {
        switch self {
        case .photo: return AyuConstants.documentTypePhoto
        case .sticker: return AyuConstants.documentTypeSticker
        case .video, .animation, .videoNote, .document, .audio: return AyuConstants.documentTypeFile
        default: return AyuConstants.documentTypeNone
        }
    }

    var isService: Bool {
        if case .service = self { return true }
        return false
    }

    /// Returns the same body with the main file replaced (used when media is copied to Saved Attachments).
    func replacingMainFile(_ file: FileRef) -> MessageBody {
        switch self {
        case .photo(var p, let c): p.file = file; return .photo(p, caption: c)
        case .video(var v, let c): v.file = file; return .video(v, caption: c)
        case .animation(var v, let c): v.file = file; return .animation(v, caption: c)
        case .videoNote(var v): v.file = file; return .videoNote(v)
        case .sticker(var s): s.file = file; return .sticker(s)
        case .document(var d, let c): d.file = file; return .document(d, caption: c)
        case .audio(var a, let c): a.file = file; return .audio(a, caption: c)
        default: return self
        }
    }

    /// Strips formatting (AyuConfig.saveFormatting = false).
    func withoutFormatting() -> MessageBody {
        func strip(_ t: RichText) -> RichText { RichText(text: t.text) }
        switch self {
        case .text(let t): return .text(strip(t))
        case .photo(let p, let c): return .photo(p, caption: strip(c))
        case .video(let v, let c): return .video(v, caption: strip(c))
        case .animation(let v, let c): return .animation(v, caption: strip(c))
        case .document(let d, let c): return .document(d, caption: strip(c))
        case .audio(let a, let c): return .audio(a, caption: strip(c))
        default: return self
        }
    }
}

enum SenderRef: Codable, Hashable {
    case user(Int64)
    case chat(Int64)

    var id: Int64 {
        switch self {
        case .user(let id), .chat(let id): return id
        }
    }
}

struct ReactionItem: Codable, Hashable {
    var emoji: String?
    var customEmojiId: Int64?
    var count: Int
    var isChosen: Bool
    var isPaid: Bool = false
}

enum SendingState: Codable, Hashable {
    case sent, pending, failed(String)
}

struct ReplyInfo: Codable, Hashable {
    var chatId: Int64
    var messageId: Int64
    var quote: String?
}

/// UI/storage representation of a Telegram message. It is Codable because the same struct is
/// stored in the AyuGram database for deleted messages and edit revisions.
struct MessageItem: Codable, Identifiable, Hashable {
    var id: Int64
    var chatId: Int64
    var sender: SenderRef
    var isOutgoing: Bool
    var date: Int
    var editDate: Int
    var body: MessageBody
    var replyTo: ReplyInfo?
    var forwardedFrom: String?
    var authorSignature: String = ""
    var viaBotUserId: Int64 = 0
    var mediaAlbumId: Int64 = 0
    var reactions: [ReactionItem] = []
    var viewCount: Int = 0
    var replyCount: Int = 0
    var isChannelPost: Bool = false
    var isPinned: Bool = false
    var sendingState: SendingState = .sent
    var canBeEditedHint: Bool = false
    var topicId: Int64 = 0
    var selfDestructIn: Double = 0
    var isScheduled: Bool = false

    // MARK: AyuGram state (not from Telegram)
    /// Message was deleted on the server, shown from the AyuGram database (🧹 mark).
    var ayuDeleted: Bool = false
    /// At least one edit revision is stored (enables "Edits history").
    var ayuHasRevisions: Bool = false

    var isEdited: Bool { editDate > 0 }
}

/// A stored edit revision (EditedMessage entity).
struct EditRevision: Codable, Identifiable, Hashable {
    var id: Int64           // fakeId
    var message: MessageItem
    var entityCreateDate: Int
}
