import Foundation
import OSLog
import ReachyJSON

/// JSON-RPC 2.0 over the same data channel, which is how daemon 1.10.0 exposes the
/// apps API.
///
/// A second framing rather than a second channel, and the daemon routes by
/// namespace: `apps.*` it answers itself, anything else it relays to the running
/// app's own `/rpc` socket and fans that app's notifications back to every client.
extension RemoteControlChannel {
    nonisolated static let log = Logger(
        subsystem: "com.alexey1312.ReachyMini",
        category: "RemoteControlChannel"
    )

    /// Ids are per channel and monotonic, which is all JSON-RPC asks of them.
    func nextRPCID() -> Int {
        lastRPCID += 1
        return lastRPCID
    }
}

public extension RemoteControlChannel {
    /// One JSON-RPC call, answered by its `id`.
    ///
    /// No turn-taking, unlike ``perform(_:payload:correlation:)``: an id is unique
    /// per call, so two calls are never each other's reply. That matters for more
    /// than tidiness — `apps.install` runs for minutes on a first install, and a
    /// status poll must not queue behind it.
    @discardableResult
    func call(
        _ method: String,
        params: [String: RemoteValue] = [:],
        timeout: Duration? = nil
    ) async throws -> Data {
        let id = nextRPCID()
        let text = try Self.encodeRPC(method: method, params: params, id: id)
        let reply = try await awaitRPCReply(id: id, sending: text, timeout: timeout)
        try Self.throwIfRPCError(in: reply)
        return reply
    }

    /// The same, with the `result` decoded.
    @discardableResult
    func call<Reply: Decodable>(
        _ method: String,
        params: [String: RemoteValue] = [:],
        timeout: Duration? = nil,
        expecting _: Reply.Type
    ) async throws -> Reply {
        let data = try await call(method, params: params, timeout: timeout)
        return try JSONCodec.daemon.decode(RPCResult<Reply>.self, from: data).result
    }

    /// The token a reply to `id` is filed under. Prefixed so it can never collide
    /// with a command name or a top-level reply key.
    static func rpcToken(_ id: Int) -> String {
        "jsonrpc:\(id)"
    }

    private static func encodeRPC(
        method: String,
        params: [String: RemoteValue],
        id: Int
    ) throws -> String {
        let body: [String: RemoteValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object(params),
            "id": .number(Double(id)),
        ]
        let encoded = try JSONCodec.daemon.encode(body)
        guard let text = String(bytes: encoded, encoding: .utf8) else {
            throw EncodingError.invalidValue(body, .init(
                codingPath: [],
                debugDescription: "rpc payload is not UTF-8"
            ))
        }
        return text
    }

    /// JSON-RPC carries its failure in an object, not in the `error` string the
    /// `{type, command}` protocol uses — so this is a second reader, not a reuse.
    /// The daemon's own `reason` rides in `data` and is kept: `already_running` is
    /// what tells a caller the robot is busy rather than broken.
    ///
    /// **The `code` is kept too, and that is the point of this shape.** It used to
    /// be folded into prose along with the reason, which left every caller with one
    /// string and no way to tell `-32601` (this build of the app has no such method,
    /// so retire the control) from `-32000` with `not_running` (the app is gone) from
    /// `app_unavailable` (it is there and not answering). Those are three different
    /// screens. The relay's own vocabulary is in `jsonrpc_relay.py`.
    ///
    /// An error object without a code falls back to ``Failure/robot(_:)``: that is
    /// not JSON-RPC-conformant, but it costs one branch to survive, and inventing a
    /// zero would hand callers a number to branch on that the robot never sent.
    private static func throwIfRPCError(in data: Data) throws {
        struct Reply: Decodable {
            struct Failure: Decodable {
                let code: Int?
                let message: String?
                let data: Detail?

                struct Detail: Decodable {
                    let reason: String?
                }
            }

            let error: Failure?
        }
        guard let failure = try? JSONCodec.daemon.decode(Reply.self, from: data).error else { return }
        let message = failure.message ?? "The robot refused the call"
        let reason = failure.data?.reason.flatMap { $0.isEmpty ? nil : $0 }
        guard let code = failure.code else {
            guard let reason else { throw Failure.robot(message) }
            throw Failure.robot("\(message) (\(reason))")
        }
        throw Failure.rpc(code: code, message: message, reason: reason)
    }
}

/// Without this every relayed failure reaches the screen as
/// `ReachyKit.RemoteControlChannel.Failure error 1` — and `.robot` already carries
/// the daemon's own sentence, composed two functions up and otherwise thrown away
/// at the presentation boundary.
extension RemoteControlChannel.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .robot(message):
            message
        case .timedOut:
            "The robot did not answer in time"
        case .closed:
            "The connection to the robot closed"
        // Deliberately the sentence `throwIfRPCError` used to compose by hand, to
        // the character. `RobotSession.message(for:)` reads `localizedDescription`,
        // so carrying the code as a field rather than in prose has to be invisible
        // to every screen — and a test pins this string for that reason.
        case let .rpc(_, message, reason):
            reason.map { "\(message) (\($0))" } ?? message
        }
    }
}
