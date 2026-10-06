import Foundation
import TDLibKit

extension TelegramService {
    func botCallback(chatId: Int64, messageId: Int64, data: Data) async throws -> BotCallbackResult {
        guard let client else { throw TelegramServiceError.notReady }
        let answer = try await client.getCallbackQueryAnswer(chatId: chatId, messageId: messageId,
            payload: .callbackQueryPayloadData(CallbackQueryPayloadData(data: data)))
        return BotCallbackResult(text: answer.text, url: answer.url)
    }

    func editCaption(chatId: Int64, messageId: Int64, text: RichText) async throws {
        guard let client, authStep == .ready else { throw TelegramServiceError.notReady }
        _ = try await client.editMessageCaption(caption: text.formattedText, chatId: chatId, messageId: messageId,
                                                replyMarkup: nil, showCaptionAboveMedia: false)
    }

    func sendVoice(chatId: Int64, path: String, duration: Int, replyToMessageId: Int64?) async throws {
        let voice = InputVoiceNote(duration: duration, voiceNote: .inputFileLocal(InputFileLocal(path: path)), waveform: Data())
        try await send(chatId: chatId, content: .inputMessageVoiceNote(InputMessageVoiceNote(
            caption: nil, selfDestructType: nil, voiceNote: voice)), replyToMessageId: replyToMessageId)
    }

    func sendVideo(chatId: Int64, path: String, width: Int, height: Int, duration: Int, replyToMessageId: Int64?) async throws {
        let video = InputVideo(addedStickerFileIds: [], cover: nil, duration: duration, height: height,
                               startTimestamp: 0, supportsStreaming: true, thumbnail: nil,
                               video: .inputFileLocal(InputFileLocal(path: path)), width: width)
        try await send(chatId: chatId, content: .inputMessageVideo(InputMessageVideo(caption: nil, hasSpoiler: false,
            selfDestructType: nil, showCaptionAboveMedia: false, video: video)), replyToMessageId: replyToMessageId)
    }

    func sendPoll(chatId: Int64, draft: PollDraft, replyToMessageId: Int64?) async throws {
        guard draft.isValid else { throw ChatFeatureError.invalidPoll }
        let type: InputPollType = draft.quiz
            ? .inputPollTypeQuiz(InputPollTypeQuiz(correctOptionIds: [draft.correctOption], explanation: RichText.empty.formattedText, explanationMedia: nil))
            : .inputPollTypeRegular(InputPollTypeRegular(allowAddingOptions: false))
        let poll = InputMessagePoll(allowsMultipleAnswers: !draft.quiz && draft.multipleAnswers,
            allowsRevoting: !draft.quiz, closeDate: 0, countryCodes: [], description: RichText.empty.formattedText,
            hideResultsUntilCloses: false, isAnonymous: draft.anonymous, isClosed: false, media: nil,
            membersOnly: false, openPeriod: 0,
            options: draft.cleanedOptions.map { InputPollOption(media: nil, text: RichText(text: $0).formattedText) },
            question: RichText(text: draft.cleanedQuestion).formattedText, shuffleOptions: false, type: type)
        try await send(chatId: chatId, content: .inputMessagePoll(poll), replyToMessageId: replyToMessageId)
    }

    func vote(chatId: Int64, messageId: Int64, options: [Int]) async throws {
        guard let client else { throw TelegramServiceError.notReady }
        try await client.setPollAnswer(chatId: chatId, messageId: messageId, optionIds: options.sorted())
    }

    func toggleReaction(_ message: MessageItem, emoji: String) async throws {
        guard let client else { throw TelegramServiceError.notReady }
        let type = ReactionType.reactionTypeEmoji(ReactionTypeEmoji(emoji: emoji))
        if message.reactions.contains(where: { $0.emoji == emoji && $0.isChosen }) {
            try await client.removeMessageReaction(chatId: message.chatId, messageId: message.id, reactionType: type)
        } else {
            try await client.addMessageReaction(chatId: message.chatId, isBig: false, messageId: message.id,
                                                reactionType: type, updateRecentReactions: true)
        }
    }

    func pinMessage(_ message: MessageItem) async throws {
        guard let client else { throw TelegramServiceError.notReady }
        if message.isPinned { try await client.unpinChatMessage(chatId: message.chatId, messageId: message.id) }
        else { try await client.pinChatMessage(chatId: message.chatId, disableNotification: true, messageId: message.id, onlyForSelf: false) }
    }

    func scheduledMessages(chatId: Int64) async throws -> [MessageItem] {
        guard let client else { throw TelegramServiceError.notReady }
        let result = try await client.getChatScheduledMessages(chatId: chatId)
        return (result.messages ?? []).map(convert).sorted { $0.date < $1.date }
    }

    func sendScheduledNow(chatId: Int64, messageId: Int64) async throws {
        guard let client else { throw TelegramServiceError.notReady }
        try await client.editMessageSchedulingState(chatId: chatId, messageId: messageId, schedulingState: nil)
    }

    func searchMessages(chatId: Int64, query: String, filter: ChatSearchFilter,
                        from: Int64 = 0, secretOffset: String = "") async throws -> MessageSearchPage {
        guard let client else { throw TelegramServiceError.notReady }
        let tdFilter: SearchMessagesFilter? = {
            switch filter {
            case .all: return nil
            case .media: return .searchMessagesFilterPhotoAndVideo
            case .files: return .searchMessagesFilterDocument
            case .links: return .searchMessagesFilterUrl
            case .pinned: return .searchMessagesFilterPinned
            }
        }()
        if case .secret = chats[chatId]?.kind {
            let result = try await client.searchSecretMessages(chatId: chatId, filter: tdFilter, limit: 50, offset: secretOffset, query: query)
            return MessageSearchPage(messages: result.messages.map(convert), nextSecretOffset: result.nextOffset, hasMore: !result.nextOffset.isEmpty)
        }
        let result = try await client.searchChatMessages(chatId: chatId, filter: tdFilter, fromMessageId: from,
            limit: 50, offset: 0, query: query, senderId: nil, topicId: nil)
        return MessageSearchPage(messages: result.messages.map(convert), nextMessageId: result.nextFromMessageId,
                                  hasMore: result.nextFromMessageId != 0)
    }

    func installedStickers(query: String = "") async throws -> [StickerItem] {
        guard let client else { throw TelegramServiceError.notReady }
        let result = try await client.getStickers(chatId: 0, limit: 200, query: query, stickerType: .stickerTypeRegular)
        if !query.isEmpty { return result.stickers.map(TDConvert.sticker) }
        let favorites = try await client.getFavoriteStickers()
        let recent = try await client.getRecentStickers(isAttached: false)
        var ids = Set<Int>()
        return (favorites.stickers + recent.stickers + result.stickers)
            .filter { ids.insert($0.sticker.id).inserted }.map(TDConvert.sticker)
    }

    func sendSticker(chatId: Int64, sticker: StickerItem, replyToMessageId: Int64?) async throws {
        let input = InputSticker(height: sticker.height, sticker: .inputFileId(InputFileId(id: sticker.file.id)),
                                 thumbnail: nil, width: sticker.width)
        try await send(chatId: chatId, content: .inputMessageSticker(InputMessageSticker(emoji: sticker.emoji, sticker: input)), replyToMessageId: replyToMessageId)
    }
}

enum ChatSearchFilter: String, CaseIterable, Identifiable {
    case all = "SearchAll", media = "SearchMedia", files = "SearchFiles", links = "SearchLinks", pinned = "PinnedMessages"
    var id: String { rawValue }
}

enum ChatFeatureError: LocalizedError {
    case invalidPoll, recordingFailed, videoExportFailed
    var errorDescription: String? {
        switch self {
        case .invalidPoll: return L("InvalidPoll")
        case .recordingFailed: return L("RecordingFailed")
        case .videoExportFailed: return L("VideoExportFailed")
        }
    }
}
