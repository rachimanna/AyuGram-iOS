import AVFoundation
import SwiftUI

struct VoiceRecordingView: View {
    let model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var recorder = VoiceRecorder()
    @State private var preview: AVAudioPlayer?
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 90)).foregroundStyle(recorder.isRecording ? .red : .accentColor)
                Text(L(recorder.isRecording ? "RecordingVoice" : "VoiceMessage")).font(.title2.bold())
                if recorder.isRecording {
                    Button(L("StopRecording")) { recorder.finish() }.buttonStyle(.borderedProminent)
                } else if let file = recorder.file {
                    Text(Formatters.duration(Int(ceil(recorder.duration)))).monospacedDigit()
                    HStack {
                        Button(L("Listen")) {
                            do {
                                try AVAudioSession.sharedInstance().setCategory(.playback)
                                try AVAudioSession.sharedInstance().setActive(true)
                                preview = try AVAudioPlayer(contentsOf: file)
                                preview?.play()
                            } catch { recorder.errorText = error.localizedDescription }
                        }.buttonStyle(.bordered)
                        Button(L("Send")) {
                            submitting = true
                            preview?.stop()
                            Task {
                                let sent = await model.sendVoice(url: file, duration: max(1, Int(ceil(recorder.duration))))
                                submitting = false
                                if sent { recorder.handedOff(); dismiss() }
                            }
                        }.buttonStyle(.borderedProminent)
                    }
                    Button(L("RecordAgain")) { preview?.stop(); Task { await recorder.start() } }
                } else {
                    Button(L("StartRecording")) { Task { await recorder.start() } }
                        .buttonStyle(.borderedProminent).disabled(recorder.isRequesting)
                }
                if let error = recorder.errorText { Text(error).foregroundStyle(.red).font(.footnote) }
                if model.errorText != nil { Text(model.errorText ?? "").foregroundStyle(.red).font(.footnote) }
                Spacer()
            }
            .padding(32)
            .navigationTitle(L("VoiceMessage"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() }.disabled(submitting) } }
            .disabled(submitting)
        }
        .interactiveDismissDisabled(submitting)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recorder.finish(); preview?.stop() }
            if phase == .background && recorder.isRequesting { recorder.cancel() }
        }
        .onDisappear { preview?.stop(); recorder.cancel() }
    }
}

struct PollComposerView: View {
    let model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PollDraft()
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L("PollQuestion")) { TextField(L("PollQuestion"), text: $draft.question, axis: .vertical) }
                Section(L("PollOptions")) {
                    ForEach(draft.options.indices, id: \.self) { i in
                        HStack {
                            TextField(LF("PollOptionNumber", i + 1), text: $draft.options[i])
                            if draft.quiz {
                                Button { draft.correctOption = i } label: {
                                    Image(systemName: draft.correctOption == i ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.borderless)
                            }
                            if draft.options.count > 2 {
                                Button {
                                    draft.options.remove(at: i)
                                    if draft.correctOption > i { draft.correctOption -= 1 }
                                    else if draft.correctOption == i { draft.correctOption = 0 }
                                } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if draft.options.count < 10 { Button(L("AddOption")) { draft.options.append("") } }
                }
                Section {
                    Toggle(L("AnonymousPoll"), isOn: $draft.anonymous).disabled(model.isChannel)
                    Toggle(L("Quiz"), isOn: $draft.quiz)
                    if !draft.quiz { Toggle(L("MultipleAnswers"), isOn: $draft.multipleAnswers) }
                }
                if let error = model.errorText { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(L("CreatePoll"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Send")) {
                        submitting = true
                        Task { if await model.sendPoll(draft) { dismiss() }; submitting = false }
                    }.disabled(!draft.isValid)
                }
            }
            .disabled(submitting)
        }
        .interactiveDismissDisabled(submitting)
    }
}

struct ScheduleMessageView: View {
    let model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(3600)
    @State private var silent = false
    @State private var submitting = false
    var body: some View {
        NavigationStack {
            Form {
                DatePicker(L("SendAt"), selection: $date, in: Date().addingTimeInterval(60)...)
                Toggle(L("SendSilently"), isOn: $silent)
                if let error = model.errorText { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(L("ScheduleMessage"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("ScheduleMessage")) {
                        submitting = true
                        model.clearError()
                        Task {
                            await model.send(delivery: MessageDelivery(silent: silent, scheduledDate: date))
                            submitting = false
                            if model.errorText == nil { dismiss() }
                        }
                    }.disabled(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.disabled(submitting)
        }.interactiveDismissDisabled(submitting)
    }
}

struct StickerPickerView: View {
    let model: ChatViewModel
    @Environment(TelegramService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var stickers: [StickerItem] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        NavigationStack {
            ScrollView {
                if loading { ProgressView().padding() }
                if let error { Text(error).foregroundStyle(.red).padding() }
                if !loading && error == nil && stickers.isEmpty { Text(L("NoRecentStickers")).padding() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) {
                    ForEach(stickers, id: \.file.id) { sticker in
                        Button {
                            Task { if await model.sendSticker(sticker) { dismiss() } else { error = model.errorText } }
                        } label: { StickerView(sticker: sticker, preferredWidth: 80).frame(width: 90, height: 100) }
                        .buttonStyle(.plain).disabled(model.isSending)
                    }
                }.padding()
            }
            .navigationTitle(L("Stickers"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .searchable(text: $query, prompt: L("Search"))
            .task(id: query) {
                loading = true; error = nil
                do {
                    if !query.isEmpty { try await Task.sleep(nanoseconds: 300_000_000) }
                    let result = try await service.installedStickers(query: query)
                    guard !Task.isCancelled else { return }
                    stickers = result
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = TelegramService.describe(error)
                }
                loading = false
            }
        }.interactiveDismissDisabled(model.isSending)
    }
}
