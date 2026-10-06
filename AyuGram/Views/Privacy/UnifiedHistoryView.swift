import SwiftUI
import UniformTypeIdentifiers

struct HistoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct HistoryExport: Codable {
    var formatVersion = 1
    var exportedAt: Date
    var accountId: Int64
    var deleted: [MessageItem]
    var revisions: [EditRevision]
}

@MainActor
enum HistoryExporter {
    static func allowed(_ message: MessageItem) -> Bool {
        guard AppLock.shared.canShowContent else { return false }
        if let chat = TelegramService.shared.chats[message.chatId] { return AppLock.shared.visible(chat) }
        return AppLock.shared.mayRevealUnknownChat(message.chatId)
    }
    static func data(deleted: [MessageItem], revisions: [EditRevision], json: Bool) throws -> Data {
        let deleted = deleted.filter(allowed), revisions = revisions.filter { allowed($0.message) }
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(HistoryExport(exportedAt: Date(), accountId: PrivacyPreferences.shared.accountId, deleted: deleted, revisions: revisions))
        }
        var lines = ["AyuGram · \(L("HistoryExport"))", "\(Date())", ""]
        for message in deleted {
            lines += ["[\(message.chatId):\(message.id)] \(Formatters.fullDateTime(message.date)) · \(L("DeletedMessages"))",
                MessagePreview.text(for: message.body), message.body.mainFile?.localPath ?? "", ""]
        }
        for revision in revisions {
            lines += ["[\(revision.message.chatId):\(revision.message.id)] \(Formatters.fullDateTime(revision.entityCreateDate)) · \(L("EditsHistoryTitle"))",
                MessagePreview.text(for: revision.message.body), ""]
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}

struct UnifiedHistoryView: View {
    var retained = false
    @Environment(TelegramService.self) private var service
    @State private var messages: [MessageItem] = []
    @State private var offset = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var exportDocument = HistoryDocument()
    @State private var exporting = false
    @State private var exportType: UTType = .json
    @State private var error = ""
    @State private var mediaViewer: MediaViewerItem?
    private var visible: [MessageItem] { messages.filter(HistoryExporter.allowed) }
    var body: some View {
        List {
            ForEach(visible, id: \.historyKey) { message in
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink(value: Route.chat(message.chatId)) {
                        Text(service.chatTitle(message.chatId).isEmpty ? "\(message.chatId)" : service.chatTitle(message.chatId)).font(.headline)
                    }
                    MessageContentView(message: message, isOutgoing: false, onMedia: { mediaViewer = $0 })
                    Text(Formatters.fullDateTime(message.date)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            else if hasMore && !retained { Button(L("LoadMore")) { Task { await load(reset: false) } } }
            if !loading && visible.isEmpty { ContentUnavailableView(L("NoSavedHistory"), systemImage: "trash.slash") }
        }.navigationTitle(L(retained ? "ViewedMediaArchive" : "DeletedFolder"))
        .toolbar {
            if !retained {
                Menu {
                    Button("JSON") { Task { await export(json: true) } }
                    Button("TXT") { Task { await export(json: false) } }
                } label: { Label(L("HistoryExport"), systemImage: "square.and.arrow.up") }
            }
        }
        .task { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .onReceive(NotificationCenter.default.publisher(for: .ayuHistoryChanged)) { _ in Task { await load(reset: true) } }
        .fullScreenCover(item: $mediaViewer) { item in MediaViewer(item: item) }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: "AyuGram-history") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
            exportDocument = HistoryDocument()
        }
        .alert(L("ErrorOccurred"), isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("OK") { error = "" } } message: { Text(error) }
    }
    private func load(reset: Bool) async {
        guard !loading else { return }; loading = true
        let account = service.myUserId
        if reset { offset = 0; messages = [] }
        let page: [MessageItem] = await withCheckedContinuation { continuation in
            if retained { AyuMessagesController.shared.retainedMedia { continuation.resume(returning: $0) } }
            else { AyuMessagesController.shared.allDeleted(limit: 100, offset: offset) { continuation.resume(returning: $0) } }
        }
        defer { loading = false }
        guard service.myUserId == account else { return }
        let existing = Set(messages.map(\.historyKey)); messages += page.filter { !existing.contains($0.historyKey) }
        offset += page.count; hasMore = page.count == 100
    }
    private func export(json: Bool) async {
        let account = service.myUserId
        let archive: ([MessageItem], [EditRevision]) = await withCheckedContinuation { continuation in
            AyuMessagesController.shared.historyArchive { continuation.resume(returning: ($0, $1)) }
        }
        guard account == service.myUserId, AppLock.shared.canShowContent else { return }
        do {
            exportDocument = HistoryDocument(data: try HistoryExporter.data(deleted: archive.0, revisions: archive.1, json: json))
            exportType = json ? .json : .plainText; exporting = true
        } catch { self.error = error.localizedDescription }
    }
}
extension MessageItem {
    var historyKey: String { "\(chatId):\(id)" }
}

struct CallLogView: View {
    @State private var confirmClear = false
    private var calls: [CallLogEntry] {
        LocalAutomation.shared.calls.filter { call in
            guard AppLock.shared.canShowContent else { return false }
            if let id = call.chatId, let chat = TelegramService.shared.chats[id] { return AppLock.shared.visible(chat) }
            return !TelegramService.shared.chats.values.contains { $0.kind.privateUserId == call.userId && !AppLock.shared.visible($0) }
        }
    }
    var body: some View {
        List {
            ForEach(calls) { call in
                HStack(spacing: 14) {
                    Image(systemName: call.video ? "video" : "phone").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TelegramService.shared.users[call.userId]?.fullName ?? "\(call.userId)").font(.headline)
                        Text(L(call.outgoing ? "OutgoingCall" : "IncomingCall")).font(.subheadline)
                        Text(call.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(call.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        if call.duration > 0 { Text(LF("SecondsCount", call.duration)).font(.caption) }
                    }
                    Spacer()
                }
            }
            if calls.isEmpty { ContentUnavailableView(L("NoCalls"), systemImage: "phone") }
        }.navigationTitle(L("CallLog"))
        .toolbar { Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") } }
        .confirmationDialog(L("ClearCallLogConfirm"), isPresented: $confirmClear) {
            Button(L("Delete"), role: .destructive) { LocalAutomation.shared.clearCalls() }
        }
    }
}
