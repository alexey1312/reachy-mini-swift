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
        let reply: Data
        do {
            reply = try await awaitRPCReply(id: id, sending: text, timeout: timeout)
        } catch Failure.timedOut {
            throw await relayIsSilent(after: method) ? Failure.relaySilent : Failure.timedOut
        }
        try Self.throwIfRPCError(in: reply)
        return reply
    }

    /// The relayed call the daemon answers itself, at once, from its own state.
    private static let relayProbe = "apps.status"

    /// Whether the JSON-RPC relay itself has died, asked only once a call has gone
    /// unanswered.
    ///
    /// The relay and the `{type, command}` protocol are served by different code on
    /// the robot, and the relay can die alone: daemons 1.10 and 1.11 wire it onto
    /// the event loop of whatever started the backend, and `POST /api/daemon/start`
    /// — this app's own Wake up after a Power off, among others — runs that start
    /// in a loop that closes as soon as its job ends. Every call then times out
    /// until the daemon *process* restarts (pollen-robotics/reachy_mini#1421, fixed
    /// by #1422, merged on 2026-10-02 and first shipped in daemon 1.12.0rc1), and a
    /// bare timeout reads as a robot that is not there.
    ///
    /// **Two probes, because a slow call is not a dead relay.** `apps.stop` waits
    /// for the app to exit, and a call relayed to the app waits on the app. A
    /// timeout there with `get_version` answering only says that the robot is
    /// there. ``relayProbe`` says whether the relay is: the daemon runs every frame
    /// in a task of its own, so a live relay answers it while the slow call is
    /// still running. A timed-out probe is its own answer. Skipped on a channel
    /// that is not open, where it would sit out a whole negotiation to learn
    /// nothing.
    private func relayIsSilent(after method: String) async -> Bool {
        guard isChannelOpen,
              await (try? perform("get_version", correlation: .replyKey("version"))) != nil
        else { return false }
        guard method != Self.relayProbe else { return true }
        let id = nextRPCID()
        do {
            let probe = try Self.encodeRPC(method: Self.relayProbe, params: [:], id: id)
            _ = try await awaitRPCReply(id: id, sending: probe, timeout: nil)
            return false
        } catch Failure.timedOut {
            return true
        } catch {
            // A closed channel or a failed send says nothing about the relay.
            return false
        }
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
        case .relaySilent:
            """
            The robot is connected, but its app relay has stopped answering — a known issue in robot \
            software 1.10 and 1.11 after its backend is started again. Restarting the robot fixes it.
            """
        }
    }
}
