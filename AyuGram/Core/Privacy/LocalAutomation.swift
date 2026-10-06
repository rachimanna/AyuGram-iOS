import Foundation
import Observation

struct PendingDeletion: Codable, Identifiable {
    var chatId: Int64
    var messageId: Int64
    var deadline: Date
    var id: String { "\(chatId):\(messageId)" }
}

struct CallLogEntry: Codable, Identifiable, Hashable {
    var id: String
    var userId: Int64
    var chatId: Int64?
    var outgoing: Bool
    var video: Bool
    var date: Date
    var state: String
    var duration: Int
}

@MainActor @Observable
final class LocalAutomation {
    static let shared = LocalAutomation()
    private(set) var calls: [CallLogEntry] = []
    private(set) var pending: [PendingDeletion] = []
    private(set) var lastError: String?
    @ObservationIgnored private var accountId: Int64 = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Set<String> = []
    private var pendingKey: String { "ayuPendingDeletes.\(accountId)" }
    private var callsKey: String { "ayuCallLog.\(accountId)" }
    func selectAccount(_ id: Int64) {
        guard id != accountId else { return }
        worker?.cancel(); inFlight = []; accountId = id
        pending = Self.load(pendingKey) ?? []
        calls = Self.load(callsKey) ?? []
        if id != 0 {
            worker = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.runDue()
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                }
            }
        }
    }
    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(pending) { UserDefaults.standard.set(data, forKey: pendingKey) }
        if let data = try? JSONEncoder().encode(calls) { UserDefaults.standard.set(data, forKey: callsKey) }
    }
    func sent(_ message: MessageItem) {
        guard accountId != 0, message.isOutgoing, !message.isScheduled, message.id > 0, !message.body.isService else { return }
        let seconds = PrivacyPreferences.shared.chat(message.chatId).autoDeleteSeconds
        guard seconds > 0 else { return }
        let entry = PendingDeletion(chatId: message.chatId, messageId: message.id, deadline: Date(timeIntervalSince1970: Double(message.date + seconds)))
        if !pending.contains(where: { $0.id == entry.id }) { pending.append(entry); persist() }
    }
    func cancelTimers(chatId: Int64) { pending.removeAll { $0.chatId == chatId }; persist() }
    func runDue() async {
        guard accountId != 0, TelegramService.shared.authStep == .ready else { return }
        let account = accountId
        for entry in pending.filter({ $0.deadline <= Date() }) {
            guard account == accountId, !Task.isCancelled, !inFlight.contains(entry.id) else { continue }
            inFlight.insert(entry.id)
            do {
                try await TelegramService.shared.delete(chatId: entry.chatId, messageIds: [entry.messageId], revoke: true)
                guard account == accountId else { return }
                pending.removeAll { $0.id == entry.id }; lastError = nil
            } catch {
                guard account == accountId else { return }
                lastError = TelegramService.describe(error)
                if let i = pending.firstIndex(where: { $0.id == entry.id }) { pending[i].deadline = Date().addingTimeInterval(60) }
            }
            inFlight.remove(entry.id); persist()
        }
    }
    /// TDLib's JSON update is used so no call engine / media negotiation is introduced.
    func ingest(_ object: [String: Any]) {
        guard accountId != 0, PrivacyPreferences.shared.snapshot.keepCallLog,
              object["@type"] as? String == "updateCall", let call = object["call"] as? [String: Any],
              let id = call["id"] as? Int, let peer = call["user_id"] as? NSNumber else { return }
        let key = "call:\(id)"
        let state = (call["state"] as? [String: Any])?["@type"] as? String ?? "callStatePending"
        if let i = calls.firstIndex(where: { $0.id == key }) { calls[i].state = state }
        else {
            calls.insert(CallLogEntry(id: key, userId: peer.int64Value, chatId: nil,
                outgoing: call["is_outgoing"] as? Bool ?? false, video: call["is_video"] as? Bool ?? false,
                date: Date(), state: state, duration: 0), at: 0)
        }
        persist()
    }
    func rememberCallMessage(_ message: MessageItem) {
        guard accountId != 0, PrivacyPreferences.shared.snapshot.keepCallLog,
              case .call(let video, let duration) = message.body else { return }
        let key = "message:\(message.chatId):\(message.id)"
        guard !calls.contains(where: { $0.id == key }) else { return }
        let peer = TelegramService.shared.chats[message.chatId]?.kind.privateUserId ?? message.sender.id
        // A live call update may already have recorded the same call. Attach its chat metadata.
        if let index = calls.firstIndex(where: { $0.id.hasPrefix("call:") && $0.userId == peer && $0.outgoing == message.isOutgoing && abs($0.date.timeIntervalSince1970 - Double(message.date)) < 120 }) {
            calls[index].chatId = message.chatId; calls[index].duration = duration
        } else {
            calls.insert(CallLogEntry(id: key, userId: peer, chatId: message.chatId, outgoing: message.isOutgoing,
                video: video, date: Date(timeIntervalSince1970: Double(message.date)), state: "callStateDiscarded", duration: duration), at: 0)
        }
        persist()
    }
    func clearCalls() { calls = []; persist() }
}
