import AVFoundation
import Lottie
import SwiftUI

struct TGSStickerView: View {
    let sticker: StickerItem
    var autoDownload = true
    @Environment(TelegramService.self) private var service
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var animation: LottieAnimation?
    @State private var visible = false

    var body: some View {
        let path = service.files.path(for: sticker.file)
        ZStack {
            if let animation {
                LottiePlayer(animation: animation, playing: visible && !reduceMotion && scenePhase == .active)
            } else {
                MediaImage(file: sticker.thumb?.file, thumb: sticker.thumb, contentMode: .fit, maxPixel: 512)
            }
        }
        .task(id: path) {
            animation = nil
            guard let path else {
                if autoDownload { service.files.request(sticker.file, priority: 8) }
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) { () -> LottieAnimation? in
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let json = try? TGSDecoder.decompress(data) else { return nil }
                return try? JSONDecoder().decode(LottieAnimation.self, from: json)
            }.value
            guard !Task.isCancelled else { return }
            animation = decoded
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

private struct LottiePlayer: UIViewRepresentable {
    let animation: LottieAnimation
    let playing: Bool

    func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView(animation: animation)
        view.contentMode = .scaleAspectFit
        view.loopMode = .loop
        view.backgroundBehavior = .pauseAndRestore
        return view
    }

    func updateUIView(_ view: LottieAnimationView, context: Context) {
        if view.animation !== animation { view.animation = animation }
        if playing {
            if !view.isAnimationPlaying { view.play() }
        } else { view.pause() }
    }

    static func dismantleUIView(_ view: LottieAnimationView, coordinator: ()) { view.stop() }
}

/// Telegram GIF messages normally contain an MP4 file. Loop without sound or controls.
struct InlineAnimationView: View {
    let video: VideoItem
    var autoDownload = true
    @Environment(TelegramService.self) private var service
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var visible = false

    var body: some View {
        let path = service.files.path(for: video.file)
        ZStack {
            MediaImage(file: video.thumb?.file, thumb: video.thumb)
            if let player { VideoLayerView(player: player) }
        }
        .task(id: path) {
            player?.pause()
            looper = nil
            player = nil
            guard let path else {
                if autoDownload { service.files.request(video.file, priority: 4) }
                return
            }
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: URL(fileURLWithPath: path)))
            player = queue
            updatePlayback()
        }
        .onAppear { visible = true; updatePlayback() }
        .onDisappear { visible = false; updatePlayback() }
        .onChange(of: scenePhase) { _, _ in updatePlayback() }
        .onChange(of: reduceMotion) { _, _ in updatePlayback() }
    }

    private func updatePlayback() {
        if visible && !reduceMotion && scenePhase == .active { player?.play() }
        else { player?.pause() }
    }
}

private struct VideoLayerView: UIViewRepresentable {
    let player: AVQueuePlayer
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: PlayerView, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: PlayerView, coordinator: ()) { view.playerLayer.player = nil }
}
