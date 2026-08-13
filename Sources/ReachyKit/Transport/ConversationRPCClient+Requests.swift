import Foundation
import ReachyJSON

/// The request half of Conversation App 1.0's JSON-RPC surface.
///
/// **One socket per call, opened and closed around it.** JSON-RPC matches a reply
/// to its request by `id`, which on a shared socket means a table of waiters, a
/// reconnect policy that survives a call in flight, and an actor to hold both —
/// against a WebSocket handshake to a robot on the same network, for a button
/// somebody presses now and then. Multiplexing onto ``turns()`` is what to do if
/// something here ever needs a call per frame rather than per tap.
public extension ConversationRPCClient {
    enum Failure: Error, Equatable {
        /// The app answered `-32601`. A build without this method, which the caller
        /// hides the control for rather than reports.
        case methodNotFound
        case rejected(code: Int, message: String)
        case timedOut
        /// The socket failed, or the app answered something that is not JSON-RPC.
        case unreachable
    }

    /// Mutes or unmutes the **robot's** microphone — nothing on this device is
    /// recording, so this switches somebody else's input off.
    func setMicrophoneMuted(_ muted: Bool) async throws {
        try await call("conversation.mic", params: ["muted": muted])
    }

    /// Stops the robot mid-sentence. The reason the dock has a button at all: a
    /// robot talking over you is answered faster from a phone than by shouting.
    func interrupt() async throws {
        try await call("conversation.interrupt", params: [String: Bool]())
    }

    private func call(_ method: String, params: [String: Bool]) async throws {
        let id = Int.random(in: 1 ... Int.max)
        let request = Request(id: id, method: method, params: params)
        guard let payload = try? JSONCodec.daemon.encode(request),
              let text = String(data: payload, encoding: .utf8)
        else { throw Failure.unreachable }

        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        do {
            try await socket.send(.string(text))
        } catch {
            throw Failure.unreachable
        }
        try await awaitReply(to: id, on: socket)
    }

    /// Races the read against one budget for the whole call.
    ///
    /// One race, not one per frame: a deadline re-armed inside the loop has to
    /// cancel the socket to end `receive()`, and `try? await Task.sleep` reports a
    /// *cancelled* sleep exactly like an elapsed one — so ending the previous
    /// iteration's timer closed the socket the next one was about to read from.
    /// Here the sleep may throw, and only a genuinely elapsed budget reaches the
    /// `cancel` below it.
    private func awaitReply(to id: Int, on socket: URLSessionWebSocketTask) async throws {
        let budget = configuration.replyTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Self.readReply(to: id, on: socket) }
            group.addTask {
                try await Task.sleep(for: budget)
                // `receive()` observes neither a deadline nor task cancellation
                // (see `ConversationRPCClient.read`), so the socket is what ends it.
                socket.cancel(with: .goingAway, reason: nil)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Reads until the reply carrying `id` arrives.
    ///
    /// Every other frame is skipped rather than taken: the app broadcasts
    /// `conversation.turn`, `.transcript` and `.level` on this same socket whenever
    /// the conversation moves, so the first frame back is regularly not the answer.
    private static func readReply(to id: Int, on socket: URLSessionWebSocketTask) async throws {
        while true {
            guard let message = try? await socket.receive() else { throw Failure.unreachable }
            let text: String? = switch message {
            case let .string(text): text
            case let .data(data): String(data: data, encoding: .utf8)
            @unknown default: nil
            }
            guard let text, let reply = reply(to: id, in: text) else { continue }
            guard let error = reply.error else { return }
            throw error.code == -32601
                ? Failure.methodNotFound
                : Failure.rejected(code: error.code, message: error.message)
        }
    }

    private struct Request: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: [String: Bool]
    }

    internal struct Reply: Decodable {
        struct Failure: Decodable {
            let code: Int
            let message: String
        }

        let error: Failure?
    }

    /// The reply to `id`, or nil for a notification or somebody else's answer.
    ///
    /// `id` is decoded loosely on purpose: JSON-RPC allows a string or a number,
    /// and an app echoing `"7"` for a request sent as `7` is answering it.
    internal static func reply(to id: Int, in frame: String) -> Reply? {
        guard let data = frame.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let answered = (object["id"] as? Int).map { $0 == id }
            ?? (object["id"] as? String).map { $0 == String(id) }
            ?? false
        guard answered else { return nil }
        return try? JSONCodec.daemon.decode(Reply.self, from: data)
    }
}
