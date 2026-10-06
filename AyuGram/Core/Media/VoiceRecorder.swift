import AVFoundation
import Foundation
import Observation

/// Native recording uses a mono M4A accepted by TDLib 1.8.67; no new binary dependency.
@MainActor
@Observable
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var isRequesting = false
    private(set) var duration: TimeInterval = 0
    private(set) var file: URL?
    var errorText: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var permissionGeneration = UUID()

    func start() async {
        guard !isRecording, !isRequesting else { return }
        isRequesting = true
        let generation = UUID()
        permissionGeneration = generation
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard permissionGeneration == generation else { return }
        isRequesting = false
        guard granted else { errorText = L("MicrophoneDenied"); return }
        cancel()
        errorText = nil
        do {
            AudioPlayback.shared.stop()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = ChatViewModel.outgoingDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            let new = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            new.delegate = self
            guard new.record(forDuration: 600) else { throw ChatFeatureError.recordingFailed }
            recorder = new
            file = url
            duration = 0
            isRecording = true
        } catch {
            cancel()
            errorText = error.localizedDescription
        }
    }

    func finish() {
        guard let recorder, isRecording else { return }
        duration = recorder.currentTime
        isRecording = false
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if duration < 0.3 { cancel() }
    }

    func cancel() {
        permissionGeneration = UUID()
        isRequesting = false
        recorder?.stop()
        recorder = nil
        isRecording = false
        duration = 0
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// TDLib owns the upload after submission; keep the source in outgoing until it has uploaded.
    func handedOff() { file = nil; duration = 0 }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.isRecording else { return }
            self.isRecording = false
            self.duration = recorder.currentTime
            self.recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            if !flag { self.cancel(); self.errorText = L("RecordingFailed") }
        }
    }
}
