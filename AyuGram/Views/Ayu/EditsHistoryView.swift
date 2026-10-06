/*
 * Port of AyuMessageHistory.java (Copyright @Radolyn, 2023, GPL-2.0):
 * "Edits history" — all stored revisions of a message, oldest first, then the current text.
 */

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EditsHistoryView: View {
    let message: MessageItem
    let model: ChatViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
    @State private var revisions: [EditRevision] = []
    @State private var loaded = false
    @State private var exporting = false
    @State private var exportDocument = HistoryDocument()
    @State private var exportType: UTType = .json
    @State private var exportError = ""

    var body: some View {
        NavigationStack {
            List {
                if loaded && revisions.isEmpty {
                    Text(L("NoEditsHistory")).foregroundStyle(.secondary)
                }
                ForEach(revisions) { rev in
                    Section {
                        revisionContent(rev.message)
                        if let index = revisions.firstIndex(where: { $0.id == rev.id }) {
                            let next = index + 1 < revisions.count ? revisions[index + 1].message : (model.message(message.id) ?? message)
                            DiffTextView(old: rev.message.body.plainText, new: next.body.plainText)
                        }
                    } header: {
                        Text(LF("RevisionSavedAt", Formatters.fullDateTime(rev.entityCreateDate)))
                    }
                }
                Section {
                    revisionContent(model.message(message.id) ?? message)
                } header: {
                    Text(message.ayuDeleted ? L("RevisionDeletedVersion") : L("RevisionCurrent"))
                }
            }
            .navigationTitle(L("EditsHistoryTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("JSON") { export(json: true) }
                        Button("TXT") { export(json: false) }
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: "AyuGram-edits") { result in
                if case .failure(let failure) = result { exportError = failure.localizedDescription }
                exportDocument = HistoryDocument()
            }
            .alert(L("ErrorOccurred"), isPresented: Binding(get: { !exportError.isEmpty }, set: { if !$0 { exportError = "" } })) {
                Button("OK") { exportError = "" }
            } message: { Text(exportError) }
            .task {
                revisions = await model.revisions(of: message)
                loaded = true
            }
        }
    }

    private func export(json: Bool) {
        guard HistoryExporter.allowed(message) else { return }
        do {
            let current = model.message(message.id) ?? message
            let versions = revisions + [EditRevision(id: 0, message: current, entityCreateDate: current.editDate > 0 ? current.editDate : current.date)]
            exportDocument = HistoryDocument(data: try HistoryExporter.data(deleted: [], revisions: versions, json: json))
            exportType = json ? .json : .plainText; exporting = true
        } catch { exportError = error.localizedDescription }
    }

    @ViewBuilder
    private func revisionContent(_ m: MessageItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch m.body {
            case .photo(let p, _):
                MediaImage(file: p.file, thumb: p.thumb, contentMode: .fit)
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            case .video(let v, _), .animation(let v, _):
                MediaImage(file: v.thumb?.file, thumb: v.thumb, contentMode: .fit)
                    .frame(maxHeight: 220)
                    .overlay { PlayBadge() }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            case .document(let d, _):
                Label(d.fileName, systemImage: "doc")
            default:
                EmptyView()
            }
            if let rich = m.body.richText {
                Text(RichTextRenderer.attributed(rich, linkColor: .accentColor, revealSpoilers: true, fontSize: appearance.messageTextSize))
                    .textSelection(.enabled)
            } else if case .text = m.body {
                Text(L("EmptyText")).italic().foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            if !m.body.plainText.isEmpty {
                Button { UIPasteboard.general.string = m.body.plainText } label: { Label(L("Copy"), systemImage: "doc.on.doc") }
            }
        }
    }
}

/// Message info: dates, ids, AyuGram state.
struct MessageDetailsView: View {
    let message: MessageItem
    @Environment(\.dismiss) private var dismiss
    @Environment(TelegramService.self) private var service

    var body: some View {
        NavigationStack {
            List {
                LabeledContent(L("DetailsSent"), value: Formatters.fullDateTime(message.date))
                if message.editDate > 0 {
                    LabeledContent(L("DetailsEdited"), value: Formatters.fullDateTime(message.editDate))
                }
                LabeledContent(L("DetailsSender"), value: service.nameOf(message.sender))
                LabeledContent("Message ID", value: "\(message.id >> 20)")
                LabeledContent("Chat ID", value: "\(message.chatId)")
                if let f = message.forwardedFrom { LabeledContent(L("ForwardedMessage"), value: f) }
                if message.ayuDeleted { LabeledContent(L("DetailsState"), value: L("DetailsDeleted")) }
                if message.ayuHasRevisions { LabeledContent(L("EditsHistoryTitle"), value: "✓") }
            }
            .navigationTitle(L("Details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct DiffTextView: View {
    let old: String
    let new: String
    private var text: Text {
        TextDiff.runs(old: old, new: new).reduce(Text("")) { result, run in
            switch run.kind {
            case .same: return result + Text(run.text)
            case .inserted: return result + Text(run.text).foregroundColor(.green).bold().underline()
            case .removed: return result + Text(run.text).foregroundColor(.red).strikethrough()
            }
        }
    }
    var body: some View {
        if old != new {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("ChangesDiff")).font(.caption.bold()).foregroundStyle(.secondary)
                text.font(.body).textSelection(.enabled)
            }
        }
    }
}
