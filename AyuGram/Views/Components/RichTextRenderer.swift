import SwiftUI

/// Builds an AttributedString from Telegram text + entities (UTF-16 offsets).
/// Links use the `ayugram://` scheme for in-app handling (mentions, hashtags, user links).
enum RichTextRenderer {
    static func attributed(_ rich: RichText, linkColor: Color, revealSpoilers: Bool = false, fontSize: CGFloat = 16) -> AttributedString {
        var result = AttributedString(rich.text)
        let ns = rich.text as NSString
        for e in rich.entities {
            let nsRange = NSRange(location: e.offset, length: e.length)
            guard e.offset >= 0, e.length > 0, NSMaxRange(nsRange) <= ns.length,
                  let range = Range(nsRange, in: result) else { continue }
            let substring = ns.substring(with: nsRange)
            switch e.kind {
            case .bold:
                result[range].inlinePresentationIntent = (result[range].inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            case .italic:
                result[range].inlinePresentationIntent = (result[range].inlinePresentationIntent ?? []).union(.emphasized)
            case .strikethrough:
                result[range].strikethroughStyle = .single
            case .underline:
                result[range].underlineStyle = .single
            case .code, .pre:
                result[range].font = .system(size: fontSize - 1, design: .monospaced)
            case .spoiler:
                if !revealSpoilers {
                    result[range].foregroundColor = .clear
                    result[range].backgroundColor = Color.secondary.opacity(0.45)
                }
            case .blockQuote:
                result[range].foregroundColor = .secondary
                result[range].inlinePresentationIntent = (result[range].inlinePresentationIntent ?? []).union(.emphasized)
            case .url:
                let s = substring.contains("://") ? substring : "https://" + substring
                if let url = URL(string: s) { link(&result, range, url, linkColor) }
            case .textUrl(let s):
                if let url = URL(string: s) { link(&result, range, url, linkColor) }
            case .email:
                if let url = URL(string: "mailto:\(substring)") { link(&result, range, url, linkColor) }
            case .phone:
                let digits = substring.filter { $0.isNumber || $0 == "+" }
                if let url = URL(string: "tel:\(digits)") { link(&result, range, url, linkColor) }
            case .mention:
                if let url = URL(string: "ayugram://resolve/\(substring.dropFirst())") { link(&result, range, url, linkColor) }
            case .mentionName(let userId):
                if let url = URL(string: "ayugram://user/\(userId)") { link(&result, range, url, linkColor) }
            case .hashtag, .cashtag:
                if let q = substring.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   let url = URL(string: "ayugram://search/\(q)") { link(&result, range, url, linkColor) }
            case .botCommand:
                if let q = substring.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   let url = URL(string: "ayugram://command/\(q)") { link(&result, range, url, linkColor) }
            case .customEmoji:
                break // rendered as the fallback emoji contained in the text
            }
        }
        return result
    }

    private static func link(_ s: inout AttributedString, _ range: Range<AttributedString.Index>, _ url: URL, _ color: Color) {
        s[range].link = url
        s[range].foregroundColor = color
    }
}
