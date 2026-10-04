import SwiftUI
import UIKit

/// Decoded-image cache shared by avatars, photos and stickers.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 400 }

    func image(at path: String) -> UIImage? { cache.object(forKey: path as NSString) }

    func load(path: String, maxPixel: CGFloat?) async -> UIImage? {
        let key = "\(path)#\(Int(maxPixel ?? 0))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let img = UIImage(contentsOfFile: path) else { return nil }
            guard let maxPixel, max(img.size.width, img.size.height) * img.scale > maxPixel * 1.5 else {
                return img.preparingForDisplay() ?? img
            }
            let target = CGSize(width: img.size.width, height: img.size.height)
            let scale = maxPixel / max(target.width, target.height)
            return img.preparingThumbnail(of: CGSize(width: target.width * scale, height: target.height * scale)) ?? img
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    static func decodeMinithumbnail(_ data: Data?) -> UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }
}

/// Displays a TDLib file as an image, downloading it on demand.
/// Placeholder chain: minithumbnail (blurred) → thumbnail file → full file.
struct MediaImage: View {
    let file: FileRef?
    var thumb: ThumbRef? = nil
    var contentMode: ContentMode = .fill
    var maxPixel: CGFloat? = 1280
    var autoDownload: Bool = true

    @Environment(TelegramService.self) private var service
    @State private var image: UIImage?
    @State private var thumbImage: UIImage?

    var body: some View {
        let path = service.files.path(for: file)
        let thumbPath = service.files.path(for: thumb?.file)
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if let thumbImage {
                Image(uiImage: thumbImage).resizable().aspectRatio(contentMode: contentMode).blur(radius: 6)
            } else if let mini = ImageCache.decodeMinithumbnail(thumb?.minithumbnail) {
                Image(uiImage: mini).resizable().aspectRatio(contentMode: contentMode).blur(radius: 8)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .clipped()
        .task(id: path) {
            if let path { image = await ImageCache.shared.load(path: path, maxPixel: maxPixel) }
            else if autoDownload { service.files.request(file, priority: 8) }
        }
        .task(id: thumbPath) {
            if image == nil, let thumbPath { thumbImage = await ImageCache.shared.load(path: thumbPath, maxPixel: 320) }
            else if image == nil { service.files.request(thumb?.file, priority: 16) }
        }
    }
}

struct AvatarView: View {
    let id: Int64
    let title: String
    let photo: PhotoRef?
    var size: CGFloat = 52
    var colorId: Int? = nil
    var isSavedMessages: Bool = false

    var body: some View {
        ZStack {
            if isSavedMessages {
                Circle().fill(Theme.avatarGradient(for: 5, colorId: 5))
                Image(systemName: "bookmark.fill").font(.system(size: size * 0.42)).foregroundStyle(.white)
            } else if let photo {
                MediaImage(file: photo.small, thumb: ThumbRef(minithumbnail: photo.minithumbnail, file: nil, width: 0, height: 0),
                           maxPixel: size * 3)
                    .clipShape(Circle())
            } else {
                Circle().fill(Theme.avatarGradient(for: id, colorId: colorId))
                Text(Self.initials(title))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    static func initials(_ title: String) -> String {
        let words = title.split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap { $0.first }.map(String.init)
        if letters.isEmpty { return String(title.prefix(1)).uppercased() }
        return letters.joined().uppercased()
    }
}
