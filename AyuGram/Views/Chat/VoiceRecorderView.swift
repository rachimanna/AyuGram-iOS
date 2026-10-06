import AVFoundation
import SwiftUI

struct VoiceRecorderView: View {
    let onSend: (URL, Int) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var recorder = VoiceRecorder()
    @State private var preview: AVAudioPlayer?
    @State private var sending = false
    @State private var sendFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: recorder.isRecording ? "mic.fill" : "waveform")
                    .font(.system(size: 48)).foregroundStyle(recorder.isRecording ? .red : .accentColor)
                Text(Formatters.duration(Int(recorder.duration))).font(.largeTitle.monospacedDigit())
                if let error = recorder.errorText { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) }
                if sendFailed { Text(L("VoiceSendFailed")).foregroundStyle(.red) }
                if recorder.isRecording {
                    Button(L("VoiceStop")) { recorder.stop() }.buttonStyle(.borderedProminent)
                } else if let file = recorder.file {
                    HStack {
                        Button(L("VoiceListen")) {
                            do {
                                preview?.stop()
                                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                                try AVAudioSession.sharedInstance().setActive(true)
                                preview = try AVAudioPlayer(contentsOf: file)
                                preview?.play()
                            } catch { recorder.errorText = error.localizedDescription }
                        }
                        Button(L("VoiceRecordAgain")) {
                            preview?.stop()
                            sendFailed = false
                            recorder.discard()
                            Task { await recorder.start() }
                        }
                    }
                    Button {
                        preview?.stop()
                        sending = true
                        Task {
                            let sent = await onSend(file, max(1, Int(recorder.duration.rounded(.up))))
                            sending = false
                            if sent { recorder.handOff(); dismiss() }
                            else { sendFailed = true }
                        }
                    } label: {
                        if sending { ProgressView() } else { Text(L("VoiceSend")) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.duration < 0.5)
                } else {
                    Button(L("VoiceRecord")) { Task { await recorder.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.requestingPermission)
                }
            }
            .padding(24)
            .disabled(sending)
            .navigationTitle(L("VoiceRecord"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Cancel")) { dismiss() }.disabled(sending)
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .presentationDetents([.medium, .large])
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recorder.stop(); preview?.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            recorder.stop()
            preview?.stop()
        }
        .onDisappear {
            preview?.stop()
            recorder.discard()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
