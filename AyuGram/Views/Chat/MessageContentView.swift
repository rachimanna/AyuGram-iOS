import MapKit
import QuickLook
import SwiftUI
import UIKit

/// Renders the body of a message inside a bubble.
struct MessageContentView: View {
    let message: MessageItem
    let isOutgoing: Bool
    let onMedia: (MediaViewerItem) -> Void

    @Environment(TelegramService.self) private var service
    @Environment(AppearanceSettings.self) private var appearance
    @State private var revealSpoilers = false

    private var linkColor: Color { isOutgoing ? .white : .accentColor }

    var body: some View {
        switch message.body {
        case .text(let t):
            textView(t)
        case .photo(let p, let caption):
            VStack(alignment: .leading, spacing: 6) {
                MediaImage(file: p.file, thumb: p.thumb, autoDownload: !isFiltered)
                    .frame(width: mediaSize(p.width, p.height).width, height: mediaSize(p.width, p.height).height)
                    .onTapGesture { onMedia(.photo(p)) }
                captionView(caption)
            }
        case .animation(let v, let caption):
            VStack(alignment: .leading, spacing: 6) {
                InlineAnimationView(video: v, autoDownload: !isFiltered)
                    .frame(width: mediaSize(v.width, v.height).width, height: mediaSize(v.width, v.height).height)
                    .onTapGesture { onMedia(.video(v)) }
                captionView(caption)
            }
        case .video(let v, let caption):
            VStack(alignment: .leading, spacing: 6) {
                MediaImage(file: v.thumb?.file, thumb: v.thumb)
                    .frame(width: mediaSize(v.width, v.height).width, height: mediaSize(v.width, v.height).height)
                    .overlay { PlayBadge(systemImage: isAnimation ? "play.rectangle.fill" : "play.fill") }
                    .overlay(alignment: .topLeading) {
                        if !isAnimation { DurationLabel(seconds: v.duration).padding(6) }
                    }
                    .onTapGesture { onMedia(.video(v)) }
                captionView(caption)
            }
        case .videoNote(let v):
            MediaImage(file: v.thumb?.file, thumb: v.thumb)
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .overlay { PlayBadge() }
                .onTapGesture { onMedia(.video(v)) }
        case .sticker(let s):
            StickerView(sticker: s, autoDownload: !isFiltered)
        case .document(let d, let caption):
            VStack(alignment: .leading, spacing: 6) {
                DocumentRow(document: d, isOutgoing: isOutgoing)
                captionView(caption)
            }
        case .audio(let a, let caption):
            VStack(alignment: .leading, spacing: 6) {
                AudioRow(audio: a, isOutgoing: isOutgoing)
                captionView(caption)
            }
        case .location(let lat, let lon):
            LocationPreview(latitude: lat, longitude: lon)
        case .contact(let name, let phone):
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.largeTitle)
                VStack(alignment: .leading) {
                    Text(name).font(.headline)
                    Text(phone).font(.subheadline)
                }
            }
        case .poll(let p):
            PollView(poll: p, message: message, isOutgoing: isOutgoing)
        case .animatedEmoji(let e):
            Text(e).font(.system(size: 64))
        case .dice(let e, let value):
            VStack {
                Text(e).font(.system(size: 64))
                if value > 0 { Text("\(value)").font(.headline) }
            }
        case .call(let isVideo, let duration):
            HStack {
                Image(systemName: isVideo ? "video.fill" : "phone.fill")
                VStack(alignment: .leading) {
                    Text(isVideo ? L("CallVideo") : L("CallVoice")).font(.subheadline.weight(.semibold))
                    if duration > 0 { Text(Formatters.duration(duration)).font(.caption) }
                }
            }
        case .expired(let s), .unsupported(let s), .service(let s):
            Text(s).italic().font(.subheadline)
        }
    }

    private var isAnimation: Bool {
        if case .animation = message.body { return true }
        return false
    }

    /// DownloadController hook: media of filtered messages is not auto-downloaded.
    private var isFiltered: Bool {
        AyuFilter.shared.isFiltered(text: message.body.plainText, dialogId: message.chatId, messageId: message.id)
    }

    private func textView(_ t: RichText) -> some View {
        Text(RichTextRenderer.attributed(t, linkColor: linkColor, revealSpoilers: revealSpoilers, fontSize: appearance.messageTextSize))
            .font(.system(size: appearance.messageTextSize))
            .tint(linkColor)
            .textSelection(.enabled)
            .padding(.trailing, 4)
            .onTapGesture { if t.entities.contains(where: { $0.kind == .spoiler }) { revealSpoilers.toggle() } }
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func captionView(_ caption: RichText) -> some View {
        if !caption.isEmpty {
            textView(caption).padding(.horizontal, 8).padding(.bottom, 4)
        }
    }

    private func mediaSize(_ w: Int, _ h: Int) -> CGSize {
        let maxW: CGFloat = 260, maxH: CGFloat = 320
        guard w > 0, h > 0 else { return CGSize(width: maxW, height: 200) }
        let ratio = CGFloat(h) / CGFloat(w)
        var width = maxW
        var height = width * ratio
        if height > maxH { height = maxH; width = height / ratio }
        return CGSize(width: max(width, 120), height: max(height, 80))
    }
}

struct StickerView: View {
    let sticker: StickerItem
    var preferredWidth: CGFloat = 170
    var autoDownload = true

    var body: some View {
        let size = CGSize(width: preferredWidth, height: sticker.width > 0 ? preferredWidth * CGFloat(sticker.height) / CGFloat(max(sticker.width, 1)) : preferredWidth)
        Group {
            switch sticker.format {
            case .webp:
                MediaImage(file: sticker.file, thumb: sticker.thumb, contentMode: .fit, maxPixel: 512, autoDownload: autoDownload)
                    .background(Color.clear)
            case .tgs:
                TGSStickerView(sticker: sticker, autoDownload: autoDownload)
            case .webm:
                // WebM/VP9 requires a separate decoder; retain the thumbnail fallback.
                if sticker.thumb?.file != nil {
                    MediaImage(file: sticker.thumb?.file, contentMode: .fit, maxPixel: 512)
                } else {
                    Text(sticker.emoji.isEmpty ? "🖼" : sticker.emoji).font(.system(size: 96))
                }
            }
        }
        .frame(width: size.width, height: min(size.height, 200))
    }
}

struct DocumentRow: View {
    let document: DocumentItem
    let isOutgoing: Bool

    @Environment(TelegramService.self) private var service
    @State private var previewURL: URL?

    var body: some View {
        let path = service.files.path(for: document.file)
        let progress = service.files.progress[document.file.id]
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(isOutgoing ? Color.white.opacity(0.25) : Color.accentColor)
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.circular).tint(.white)
                } else {
                    Image(systemName: path != nil ? "doc.fill" : "arrow.down").foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.fileName.isEmpty ? L("AttachDocument") : document.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(Formatters.fileSize(document.file.size)).font(.caption).opacity(0.75)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let path { previewURL = URL(fileURLWithPath: path) }
            else if progress != nil { service.files.cancel(document.file) }
            else { service.files.download(document.file) }
        }
        .quickLookPreview($previewURL)
    }
}

struct AudioRow: View {
    let audio: AudioItem
    let isOutgoing: Bool

    @Environment(TelegramService.self) private var service
    @State private var playback = AudioPlayback.shared
    @State private var wantsPlay = false

    var body: some View {
        let path = service.files.path(for: audio.file)
        let current = playback.isCurrent(audio.file)
        HStack(spacing: 10) {
            Button {
                if let path {
                    playback.toggle(file: audio.file, path: path, isVoice: audio.isVoice)
                } else {
                    wantsPlay = true
                    service.files.download(audio.file)
                }
            } label: {
                ZStack {
                    Circle().fill(isOutgoing ? Color.white.opacity(0.25) : Color.accentColor)
                    if service.files.progress[audio.file.id] != nil || (current && playback.isPreparing) {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: current && playback.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                if audio.isVoice {
                    WaveformView(waveform: audio.waveform, progress: current ? playback.progress : 0, isOutgoing: isOutgoing)
                        .frame(width: 150, height: 22)
                } else {
                    Text(audio.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !audio.performer.isEmpty { Text(audio.performer).font(.caption).lineLimit(1) }
                }
                Text(Formatters.duration(audio.duration)).font(.caption.monospacedDigit()).opacity(0.75)
            }
        }
        .onChange(of: path) { _, newPath in
            if wantsPlay, let newPath {
                wantsPlay = false
                playback.toggle(file: audio.file, path: newPath, isVoice: audio.isVoice)
            }
        }
    }
}

/// Telegram voice waveform: 5-bit samples packed into bytes.
struct WaveformView: View {
    let waveform: Data?
    let progress: Double
    let isOutgoing: Bool

    private var samples: [CGFloat] {
        guard let waveform, !waveform.isEmpty else { return Array(repeating: 0.3, count: 40) }
        let bytes = [UInt8](waveform)
        let count = bytes.count * 8 / 5
        var values: [CGFloat] = []
        for i in 0..<count {
            let bit = i * 5
            let byteIndex = bit / 8, shift = bit % 8
            var v = Int(bytes[byteIndex]) >> shift
            if shift > 3, byteIndex + 1 < bytes.count { v |= Int(bytes[byteIndex + 1]) << (8 - shift) }
            values.append(CGFloat(v & 31) / 31)
        }
        // Downsample to ~40 bars
        let step = max(1, values.count / 40)
        return stride(from: 0, to: values.count, by: step).map { values[$0] }
    }

    var body: some View {
        GeometryReader { geo in
            let bars = samples
            let barWidth = max(2, geo.size.width / CGFloat(bars.count) - 1)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(bars.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(i) / Double(bars.count) <= progress && progress > 0
                              ? (isOutgoing ? Color.white : Color.accentColor)
                              : (isOutgoing ? Color.white.opacity(0.45) : Color.secondary.opacity(0.5)))
                        .frame(width: barWidth, height: max(2, v * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct LocationPreview: View {
    let latitude: Double
    let longitude: Double

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800))) {
            Marker("", coordinate: coordinate)
        }
        .frame(width: 240, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if let url = URL(string: "http://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(latitude),\(longitude)") {
                        UIApplication.shared.open(url)
                    }
                }
        }
    }
}

struct PollView: View {
    let poll: PollItem
    let message: MessageItem
    let isOutgoing: Bool
    @Environment(TelegramService.self) private var service
    @State private var selection: Set<Int> = []
    @State private var submitting = false
    @State private var error: String?

    private var canVote: Bool { !poll.isClosed && !message.ayuDeleted && poll.canVote != false && !submitting }
    private var chosen: Set<Int> { Set(poll.options.indices.filter { poll.options[$0].isChosen }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(poll.question).font(.headline)
            Text(poll.isQuiz ? L("Quiz") : L("Poll")).font(.caption).opacity(0.7)
            ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                Button {
                    if poll.allowsMultipleAnswers == true {
                        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
                    } else { Task { await vote([index]) } }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            if poll.canSeeResults != false { Text("\(option.votePercentage)%").font(.caption.bold()).frame(width: 40, alignment: .leading) }
                            Text(option.text).font(.subheadline)
                            if option.isChosen || selection.contains(index) { Image(systemName: "checkmark.circle.fill").font(.caption) }
                        }
                        if poll.canSeeResults != false {
                            GeometryReader { geometry in
                                Capsule().fill(isOutgoing ? Color.white : Color.accentColor)
                                    .frame(width: max(4, geometry.size.width * CGFloat(option.votePercentage) / 100))
                            }.frame(height: 4)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!canVote)
            }
            if poll.allowsMultipleAnswers == true && !poll.isClosed && !message.ayuDeleted {
                Button(L("Vote")) { Task { await vote(selection.sorted()) } }.disabled(!canVote || selection.isEmpty)
            }
            if !chosen.isEmpty && !poll.isQuiz && !poll.isClosed && !message.ayuDeleted {
                Button(L("RetractVote")) { Task { await vote([]) } }.font(.caption).disabled(!canVote)
            }
            Text(LF("VotesCount", poll.totalVoters)).font(.caption).opacity(0.7)
            if poll.isClosed { Text(L("PollClosed")).font(.caption) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .frame(minWidth: 220)
        .onAppear { selection = chosen }
        .onChange(of: chosen) { _, value in selection = value }
    }

    private func vote(_ ids: [Int]) async {
        guard canVote else { return }
        submitting = true; error = nil
        defer { submitting = false }
        do { try await service.vote(chatId: message.chatId, messageId: message.id, options: ids) }
        catch { self.error = TelegramService.describe(error) }
    }
}
