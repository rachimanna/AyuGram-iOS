import Foundation

enum Formatters {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        return f
    }()

    private static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMM")
        return f
    }()

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func date(_ unix: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(unix)) }

    /// Message bubble time ("14:05").
    static func messageTime(_ unix: Int) -> String { time.string(from: date(unix)) }

    /// Chat list time: today → time, this week → weekday, this year → "3 Oct", else full date.
    static func chatListTime(_ unix: Int) -> String {
        guard unix > 0 else { return "" }
        let d = date(unix)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return weekday.string(from: d)
        }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return shortDate.string(from: d) }
        return fullDate.string(from: d)
    }

    /// Date separator inside a chat.
    static func dayHeader(_ unix: Int) -> String {
        let d = date(unix)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return L("Today") }
        if cal.isDateInYesterday(d) { return L("Yesterday") }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return dayHeader.string(from: d) }
        return fullDate.string(from: d)
    }

    static func fullDateTime(_ unix: Int) -> String { dateTime.string(from: date(unix)) }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func compactCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    static func presence(_ p: UserPresence) -> String {
        switch p {
        case .online: return L("Online")
        case .offline(let was):
            let d = date(was)
            let cal = Calendar.current
            if Date().timeIntervalSince(d) < 60 { return L("LastSeenJustNow") }
            if cal.isDateInToday(d) { return LF("LastSeenAt", time.string(from: d)) }
            if cal.isDateInYesterday(d) { return LF("LastSeenYesterdayAt", time.string(from: d)) }
            return LF("LastSeenDate", shortDate.string(from: d))
        case .recently: return L("LastSeenRecently")
        case .lastWeek: return L("LastSeenWeek")
        case .lastMonth: return L("LastSeenMonth")
        case .longTimeAgo, .unknown: return L("LastSeenLongTime")
        case .bot: return L("Bot")
        }
    }

    static func members(_ n: Int, channel: Bool) -> String {
        LF(channel ? "SubscribersCount" : "MembersCount", n)
    }
}
