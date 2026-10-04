import Foundation

/// One-line message descriptions for the chat list, replies and notifications.
enum MessagePreview {
    static func text(for body: MessageBody) -> String {
        switch body {
        case .text(let t): return t.text
        case .photo(_, let c): return prefixed("🖼", L("AttachPhoto"), c.text)
        case .video(_, let c): return prefixed("📹", L("AttachVideo"), c.text)
        case .animation(_, let c): return prefixed("", L("AttachGif"), c.text)
        case .videoNote: return L("AttachRound")
        case .sticker(let s): return s.emoji.isEmpty ? L("AttachSticker") : "\(s.emoji) \(L("AttachSticker"))"
        case .document(let d, let c): return prefixed("📎", d.fileName.isEmpty ? L("AttachDocument") : d.fileName, c.text)
        case .audio(let a, let c):
            if a.isVoice { return prefixed("🎤", L("AttachAudio"), c.text) }
            return prefixed("🎵", [a.performer, a.title].filter { !$0.isEmpty }.joined(separator: " — "), c.text)
        case .location: return "📍 " + L("AttachLocation")
        case .contact(let name, _): return "👤 " + name
        case .poll(let p): return "📊 " + p.question
        case .animatedEmoji(let e): return e
        case .dice(let e, _): return e
        case .call(let isVideo, _): return isVideo ? L("CallVideo") : L("CallVoice")
        case .expired(let s), .service(let s), .unsupported(let s): return s
        }
    }

    private static func prefixed(_ icon: String, _ label: String, _ caption: String) -> String {
        let main = caption.isEmpty ? label : caption
        return icon.isEmpty ? main : "\(icon) \(main)"
    }
}
