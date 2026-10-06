import AVFoundation
import Observation

@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var duration: TimeInterval = 0
    private(set) var file: URL?
    private(set) var requestingPermission = false
    var errorText: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var cancelled = false

    func start() async {
        guard !isRecording, !requestingPermission, file == nil else { return }
        requestingPermission = true
        cancelled = false
        defer { requestingPermission = false }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard !cancelled, !Task.isCancelled else { return }
        guard allowed else { errorText = L("VoiceMicrophoneDenied"); return }
        let url = ChatViewModel.outgoingDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            AudioPlayback.shared.stop()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let audio = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            guard audio.record(forDuration: 600) else { throw CocoaError(.fileWriteUnknown) }
            recorder = audio
            file = url
            duration = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let recorder = self.recorder else { return }
                    self.duration = recorder.currentTime
                    if !recorder.isRecording { self.stop() }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorText = error.localizedDescription
        }
    }

    func stop() {
        guard isRecording else { return }
        duration = max(duration, recorder?.currentTime ?? 0)
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// TDLib owns the outgoing file after a successful enqueue; leave it in place.
    func handOff() { stop(); file = nil }

    func discard() {
        cancelled = true
        stop()
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        duration = 0
    }
}
