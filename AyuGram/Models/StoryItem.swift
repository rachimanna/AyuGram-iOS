import Foundation

struct StoryReference: Hashable, Identifiable {
    let chatId: Int64
    let storyId: Int
    var id: String { "\(chatId):\(storyId)" }
}

struct ChatStoryGroup: Identifiable {
    let id: Int64
    var order: Int64
    var references: [StoryReference]
    var maxReadStoryId: Int
    var hasUnread: Bool { references.contains { $0.storyId > maxReadStoryId } }
    var firstUnreadIndex: Int {
        references.firstIndex { $0.storyId > maxReadStoryId } ?? 0
    }
}

struct StoryItem {
    enum Content {
        case photo(PhotoItem)
        case video(VideoItem)
        case unsupported
    }
    let reference: StoryReference
    let caption: RichText
    let content: Content
    var file: FileRef? {
        switch content {
        case .photo(let photo): return photo.file
        case .video(let video): return video.file
        case .unsupported: return nil
        }
    }
}
