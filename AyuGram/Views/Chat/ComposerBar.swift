import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// ChatActivityEnterView: text input, attachments, reply/edit banner.
struct ComposerBar: View {
    @Bindable var model: ChatViewModel

    @Environment(TelegramService.self) private var service
    @Environment(AyuConfig.self) private var ayu
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showStickerPicker = false
    @State private var showVoiceRecorder = false
    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let banner = bannerInfo {
                HStack(spacing: 10) {
                    Image(systemName: banner.icon).foregroundStyle(.tint)
                    RoundedRectangle(cornerRadius: 1.5).fill(.tint).frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(banner.title).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        Text(banner.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.cancelComposerMode() } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            if model.canWrite {
                inputRow
            } else {
                readOnlyRow
            }
        }
        .background(.bar)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await model.sendPhoto(data: data)
                    }
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { for url in urls { await model.sendFile(url: url) } }
        }
        .sheet(isPresented: $showStickerPicker) {
            StickerPickerView { sticker in
                Task { await model.sendSticker(sticker) }
            }
            .environment(service)
        }
        .sheet(isPresented: $showVoiceRecorder) {
            VoiceRecorderView { url, duration in await model.sendVoiceNote(url: url, duration: duration) }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { showPhotoPicker = true } label: { Label(L("AttachPhoto"), systemImage: "photo") }
                Button { showFileImporter = true } label: { Label(L("AttachDocument"), systemImage: "doc") }
                Button { showStickerPicker = true } label: { Label(L("AttachSticker"), systemImage: "face.smiling") }
                if !isEditing {
                    Button { showVoiceRecorder = true } label: { Label(L("VoiceRecord"), systemImage: "mic") }
                }
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            TextField(L("TypeMessage"), text: $model.composerText, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            Button {
                Task { await model.send() }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    // AyuGram "Schedule messages": every message is sent as a 12-second scheduled message.
                    if ayu.useScheduledMessages && !isEditing {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .background(Circle().fill(.orange).frame(width: 15, height: 15))
                    }
                }
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var readOnlyRow: some View {
        let chat = service.chats[model.chatId]
        HStack {
            Spacer()
            if case .channel(let id) = chat?.kind, service.supergroups[id]?.isMember == false {
                Button(L("JoinChannel")) { Task { try? await service.joinChat(model.chatId) } }
                    .font(.headline)
            } else if case .supergroup(let id) = chat?.kind, service.supergroups[id]?.isMember == false {
                Button(L("JoinGroup")) { Task { try? await service.joinChat(model.chatId) } }
                    .font(.headline)
            } else {
                Button(chat?.isMuted == true ? L("Unmute") : L("Mute")) {
                    Task { await service.setMuted(chatId: model.chatId, muted: !(chat?.isMuted ?? false)) }
                }
                .font(.headline)
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var isEditing: Bool {
        if case .edit = model.mode { return true }
        return false
    }

    private var canSend: Bool {
        !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bannerInfo: (icon: String, title: String, text: String)? {
        switch model.mode {
        case .normal: return nil
        case .reply(let m): return ("arrowshape.turn.up.left", service.nameOf(m.sender), MessagePreview.text(for: m.body))
        case .edit(let m): return ("pencil", L("EditMessage"), MessagePreview.text(for: m.body))
        }
    }
}

private struct StickerPickerView: View {
    @Environment(TelegramService.self) private var service
    @Environment(\.dismiss) private var dismiss
    let onSelect: (StickerItem) -> Void

    @State private var stickers: [StickerItem] = []
    @State private var isLoading = true
    @State private var query = ""
    @State private var errorText: String?
    @State private var attempt = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    VStack(spacing: 12) {
                        Text(errorText).multilineTextAlignment(.center)
                        Button(L("Retry")) { attempt += 1 }
                    }
                    .padding()
                } else if stickers.isEmpty {
                    ContentUnavailableView(L("StickersUnavailable"), systemImage: "face.smiling")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(stickers, id: \.file.id) { sticker in
                                Button {
                                    onSelect(sticker)
                                    dismiss()
                                } label: {
                                    StickerView(sticker: sticker, preferredWidth: 56)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 64)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle(L("AttachSticker"))
            .searchable(text: $query, prompt: L("Search"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .task(id: "\(query):\(attempt)") {
            isLoading = true
            errorText = nil
            do {
                if !query.isEmpty { try await Task.sleep(nanoseconds: 300_000_000) }
                let result = try await service.installedStickers(query: query)
                guard !Task.isCancelled else { return }
                stickers = result
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                errorText = TelegramService.describe(error)
                isLoading = false
            }
        }
        .presentationDetents([.medium, .large])
    }
}
