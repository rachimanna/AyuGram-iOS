/*
 * Port of AyuSyncController / AyuSyncWebSocketClient / AyuSyncConfig and sync models
 * (Copyright @Radolyn, 2023, GPL-2.0). OkHttp + java-websocket → URLSession / URLSessionWebSocketTask.
 *
 * Protocol (unchanged):
 *   POST {http}/sync/register/v1   {"name", "identifier"}           Authorization: <token>
 *   POST {http}/sync/force/v1      {"userId", "fromDate": 0}
 *   WS   {ws}/sync/ws/v1           headers X-APP-PACKAGE, X-DEVICE-IDENTIFIER, Authorization
 *   messages: {"type": "sync_read" | "sync_batch" | "sync_force" | "sync_force_finish", "userId", "args": {…}}
 *   dialogId uses Telegram Android ids (user = id, group/channel = -id).
 */

import Foundation
import Observation
import UIKit

enum AyuSyncConnectionState: String {
    case disconnected, connecting, connected, error
}

@MainActor
@Observable
final class AyuSyncController {
    static let shared = AyuSyncController()

    private(set) var state: AyuSyncConnectionState = .disconnected
    private(set) var lastSent: Date?
    private(set) var lastReceived: Date?
    private(set) var registerStatusCode: Int?

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var userId: Int64 = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private let session = URLSession(configuration: .default)
    @ObservationIgnored private let config = AyuConfig.shared

    // MARK: Config (AyuSyncConfig)

    private var httpBase: String { (config.useSecureConnection ? "https://" : "http://") + config.syncServerURL }
    private var wsBase: String { (config.useSecureConnection ? "wss://" : "ws://") + config.syncServerURL }
    var profileURL: URL? { URL(string: "\(httpBase)/ui/profile?token=\(config.syncServerToken)") }

    private var deviceIdentifier: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }

    private var packageName: String { Bundle.main.bundleIdentifier ?? "com.ayugram.port" }

    // MARK: Lifecycle

    func accountReady(userId: Int64) {
        self.userId = userId
        restart()
    }

    func restart() {
        disconnect()
        guard config.syncEnabled, !config.syncServerToken.isEmpty, userId != 0 else { return }
        Task {
            await registerDevice()
            connect()
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .disconnected
    }

    private func registerDevice() async {
        guard let url = URL(string: "\(httpBase)/sync/register/v1") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(config.syncServerToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": UIDevice.current.name, "identifier": deviceIdentifier])
        do {
            let (_, response) = try await session.data(for: request)
            registerStatusCode = (response as? HTTPURLResponse)?.statusCode
        } catch {
            registerStatusCode = nil
            AppLog.debug("AyuSync register failed: \(error)")
        }
    }

    func forceSync() async {
        guard let url = URL(string: "\(httpBase)/sync/force/v1") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(config.syncServerToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["userId": userId, "fromDate": 0])
        _ = try? await session.data(for: request)
    }

    private func connect() {
        guard let url = URL(string: "\(wsBase)/sync/ws/v1") else { state = .error; return }
        var request = URLRequest(url: url)
        request.setValue(packageName, forHTTPHeaderField: "X-APP-PACKAGE")
        request.setValue(deviceIdentifier, forHTTPHeaderField: "X-DEVICE-IDENTIFIER")
        request.setValue(config.syncServerToken, forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        socket = task
        state = .connecting
        task.resume()
        receive(on: task)
        // URLSessionWebSocketTask has no onOpen callback; a successful ping means connected.
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                if error == nil { self.state = .connected } else { self.handleFailure(task) }
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    self?.handleFailure(task)
                    return
                }
                guard let self, self.socket === task else { return }
                self.state = .connected
                self.lastReceived = Date()
                switch message {
                case .string(let s): self.handleIncoming(Data(s.utf8))
                case .data(let d): self.handleIncoming(d)
                @unknown default: break
                }
            }
        }
    }

    private func handleFailure(_ task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        socket = nil
        state = .error
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.config.syncEnabled else { return }
            self.connect()
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket, state == .connected,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        lastSent = Date()
        Task { try? await socket.send(.string(text)) }
    }

    // MARK: Incoming (invokeHandler)

    private func handleIncoming(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        invokeHandler(json)
    }

    private func invokeHandler(_ req: [String: Any]) {
        guard let type = req["type"] as? String else { return }
        let reqUser = (req["userId"] as? NSNumber)?.int64Value ?? 0
        guard reqUser == userId else {
            AppLog.debug("AyuSync: sync for unknown account \(reqUser)")
            return
        }
        switch type {
        case "sync_force":
            onForceSync()
        case "sync_batch":
            let events = (req["args"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
            events.forEach(invokeHandler)
        case "sync_read":
            guard let args = req["args"] as? [String: Any],
                  let dialogId = (args["dialogId"] as? NSNumber)?.int64Value,
                  let untilId = (args["untilId"] as? NSNumber)?.int64Value else { return }
            onSyncRead(dialogId: dialogId, untilId: untilId)
        default:
            AppLog.debug("AyuSync: unknown sync type \(type)")
        }
    }

    /// Android: AyuGhostUtils.markReadLocally — the read state comes from another device,
    /// so it is applied locally without sending a read packet.
    private func onSyncRead(dialogId: Int64, untilId: Int64) {
        let chatId = Self.tdChatId(fromAndroidDialogId: dialogId)
        // Android message ids == server ids; TDLib message id = server id << 20.
        LocalReadStore.shared.markRead(chatId: chatId, until: untilId << 20)
    }

    private func onForceSync() {
        let service = TelegramService.shared
        let events: [[String: Any]] = service.chats.values.map { chat in
            [
                "type": "sync_read",
                "userId": userId,
                "args": [
                    "dialogId": Self.androidDialogId(chat: chat),
                    "untilId": chat.lastReadInboxMessageId >> 20,
                    "unread": chat.unreadCount,
                ] as [String: Any],
            ]
        }
        send(["type": "sync_batch", "userId": userId, "args": ["events": events]])
        send(["type": "sync_force_finish", "userId": userId, "args": [String: Any]()])
    }

    // MARK: Outgoing (syncRead)

    func syncRead(chatId: Int64, untilId: Int64, unread: Int) {
        guard config.syncEnabled, state == .connected, let chat = TelegramService.shared.chats[chatId] else { return }
        send([
            "type": "sync_read",
            "userId": userId,
            "args": ["dialogId": Self.androidDialogId(chat: chat), "untilId": untilId >> 20, "unread": unread] as [String: Any],
        ])
    }

    // MARK: Id mapping (TDLib chat id ↔ Telegram Android dialog id)

    static func androidDialogId(chat: ChatItem) -> Int64 {
        switch chat.kind {
        case .basicGroup(let id): return -id
        case .supergroup(let id), .channel(let id): return -id
        default: return chat.kind.privateUserId ?? chat.id
        }
    }

    static func tdChatId(fromAndroidDialogId dialogId: Int64) -> Int64 {
        if dialogId > 0 { return dialogId }
        // Negative: either a basic group (-chatId) or a channel (-channelId). Prefer a known supergroup.
        let id = -dialogId
        let supergroupChatId = -1_000_000_000_000 - id
        if TelegramService.shared.chats[supergroupChatId] != nil { return supergroupChatId }
        return dialogId
    }
}
