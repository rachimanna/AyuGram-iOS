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
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { showPhotoPicker = true } label: { Label(L("AttachPhoto"), systemImage: "photo") }
                Button { showFileImporter = true } label: { Label(L("AttachDocument"), systemImage: "doc") }
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
