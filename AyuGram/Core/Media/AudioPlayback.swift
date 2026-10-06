import AVFoundation
import Foundation
import Observation

/// MediaController (Android) → AVAudioPlayer. Plays voice notes and music, one at a time.
@MainActor
@Observable
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    private(set) var currentFileId: Int?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var isPreparing = false
    private(set) var errorText: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func isCurrent(_ file: FileRef) -> Bool { currentFileId == file.id }

    /// `path` is the local Ogg/Opus (voice) or audio file.
    func toggle(file: FileRef, path: String, isVoice: Bool) {
        if currentFileId == file.id, let player {
            if player.isPlaying { pause() } else { resume() }
            return
        }
        stop()
        currentFileId = file.id
        isPreparing = true
        errorText = nil
        let key = file.uniqueId ?? "\(file.id)"
        Task {
            do {
                let url: URL
                // TDLib also accepts M4A voice messages. Detect Ogg by its header because
                // downloaded files often have no extension.
                if Self.isOggFile(path) {
                    url = try await Task.detached(priority: .userInitiated) {
                        try OpusOggDecoder.wavFile(for: URL(fileURLWithPath: path), cacheKey: key)
                    }.value
                } else {
                    url = URL(fileURLWithPath: path)
                }
                guard currentFileId == file.id else { return }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                player = p
                isPreparing = false
                resume()
            } catch {
                isPreparing = false
                errorText = error.localizedDescription
                currentFileId = nil
            }
        }
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = player.duration * max(0, min(1, fraction))
        progress = fraction
    }

    nonisolated static func isOggFile(_ path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("OggS".utf8)
    }

    private func resume() {
        player?.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        progress = 0
        currentFileId = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
