import AVKit
import Photos
import SwiftUI

/// PhotoViewer: full-screen photo with zoom, video playback, save/share.
struct MediaViewer: View {
    let item: MediaViewerItem

    @Environment(TelegramService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var player: AVPlayer?
    @State private var savedText: String?

    private var file: FileRef {
        switch item {
        case .photo(let p): return p.file
        case .video(let v): return v.file
        }
    }

    var body: some View {
        let path = service.files.path(for: file)
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch item {
                case .photo(let p):
                    MediaImage(file: p.file, thumb: p.thumb, contentMode: .fit, maxPixel: 4096)
                        .scaleEffect(scale)
                        .gesture(MagnificationGesture()
                            .onChanged { scale = max(1, lastScale * $0) }
                            .onEnded { _ in lastScale = scale })
                        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; lastScale = scale } }
                case .video(let v):
                    if let player {
                        VideoPlayer(player: player)
                            .onAppear { player.play() }
                    } else {
                        ZStack {
                            MediaImage(file: v.thumb?.file, thumb: v.thumb, contentMode: .fit)
                            if let progress = service.files.progress[v.file.id] {
                                ProgressView(value: progress).progressViewStyle(.circular).tint(.white).scaleEffect(1.6)
                            } else {
                                ProgressView().tint(.white)
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let path {
                        ShareLink(item: URL(fileURLWithPath: path)) { Image(systemName: "square.and.arrow.up") }
                        Button { saveToPhotos(path) } label: { Image(systemName: "square.and.arrow.down") }
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .tint(.white)
            .overlay(alignment: .bottom) {
                if let savedText {
                    Text(savedText).padding(10).background(.thinMaterial, in: Capsule()).padding(.bottom, 40)
                }
            }
        }
        .task(id: path) {
            guard case .video = item else { return }
            if let path {
                // TDLib files have no extension; give AVPlayer a hint via a symlink with .mp4.
                player = AVPlayer(url: Self.playableURL(for: path))
            } else {
                service.files.download(file)
            }
        }
        .onDisappear { player?.pause() }
    }

    private func saveToPhotos(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let isVideo: Bool = { if case .video = item { return true }; return false }()
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: Self.playableURL(for: path))
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }) { ok, _ in
                Task { @MainActor in
                    savedText = ok ? L("SavedToGallery") : L("ErrorOccurred")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    savedText = nil
                }
            }
        }
    }

    static func playableURL(for path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.isEmpty else { return url }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent + ".mp4")
        if !FileManager.default.fileExists(atPath: link.path) {
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        }
        return link
    }
}
