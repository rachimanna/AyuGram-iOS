/*
 * Port of AyuMessageHistory.java (Copyright @Radolyn, 2023, GPL-2.0):
 * "Edits history" — all stored revisions of a message, oldest first, then the current text.
 */

import SwiftUI
import UIKit

struct EditsHistoryView: View {
    let message: MessageItem
    let model: ChatViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
    @State private var revisions: [EditRevision] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded && revisions.isEmpty {
                    Text(L("NoEditsHistory")).foregroundStyle(.secondary)
                }
                ForEach(revisions) { rev in
                    Section {
                        revisionContent(rev.message)
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
            }
            .task {
                revisions = await model.revisions(of: message)
                loaded = true
            }
        }
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
