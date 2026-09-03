import Foundation
import ReachyJSON

/// The WebRTC data channel, with the WebRTC left out.
///
/// A seam rather than an `RTCDataChannel`: the protocol above it is plain JSON
/// and belongs with the rest of the daemon's vocabulary, in a module that does
/// not link a media framework.
public protocol RemoteDataChannel: Sendable {
    func send(_ text: String) async throws
    /// Sends only when a channel is attached right now. Unlike ``send(_:)``, this
    /// must never wait through a peer replacement: live-control frames are stale
    /// by the time the next peer arrives.
    func sendIfOpen(_ text: String) async throws -> Bool
    func messages() -> AsyncStream<String>
    /// Whether a command sent now would go out, rather than wait for a channel the
    /// robot has not opened yet. Deliberately the same question `send` asks itself
    /// before deciding to wait — a caller bounding that wait has to bound the same
    /// thing, or it is timing something other than what is happening.
    var isOpen: Bool { get }
}

public extension RemoteDataChannel {
    /// Conservative default for test doubles and transports whose `send` does not
    /// wait. The WebRTC implementation overrides this so the check and choice not
    /// to wait are made against the same attached channel.
    func sendIfOpen(_ text: String) async throws -> Bool {
        guard isOpen else { return false }
        try await send(text)
        return true
    }
}

/// Drives the robot over the reliable `"data"` channel of a WebRTC session.
///
/// This is the whole control surface of a remote session: the daemon's HTTP API
/// is not reachable from outside the robot's network, and the same commands
/// arrive here as JSON instead.
///
/// **The plain command protocol carries no request id.** Most commands are
/// answered by echoing the name back — `{"status": "ok", "command": "wake_up",
/// "completed": true}` — but a handful answer with the bare payload and no name:
/// `get_version` sends `{"version": …}`, `get_state` sends `{"state": …}` and
/// both motor-mode commands send `{"motor_mode": …}`. Such a reply can only be
/// attributed by something the caller supplies, which is what `Correlation` is,
/// and two commands sharing a token are serialised rather than guessed at. The
/// JSON-RPC surface daemon 1.10.0 added beside it *does* carry an id — see
/// ``call(_:params:timeout:)``.
public actor RemoteControlChannel {
    /// How a command's reply is recognised on a channel that carries no ids.
    public enum Correlation: Sendable, Equatable {
        /// The reply echoes the command name. The common case.
        case echoedCommand
        /// The reply names nothing; this top-level key identifies it. Both
        /// motor-mode commands answer under `motor_mode`, so they serialise
        /// against each other — which is correct, since nothing tells them apart.
        case replyKey(String)
        /// The reply names a `type`, the way a broadcast does. Daemon 1.10.0
        /// answers `get_imu` with `ImuDataMsg`, which is also what the robot
        /// publishes unasked — so the same frame serves both, and the first one to
        /// arrive answers the question. Only for replies that really are a reading
        /// rather than an acknowledgement.
        case typed(String)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The robot answered, and said no. The text is its own.
        case robot(String)
        /// Nothing came back in time. Nothing on this channel promises a deadline,
        /// so one is imposed here — a caller left awaiting forever is worse off
        /// than one told the robot went quiet.
        case timedOut
        case closed
        /// A JSON-RPC refusal, with the two fields a caller can branch on.
        ///
        /// **Appended, and it has to be**: `NSError` numbers a bridged case by its
        /// declaration index, so inserting this beside ``robot(_:)`` where it reads
        /// better would renumber ``closed`` — which the notes record as "error 2".
        ///
        /// Separate from ``robot(_:)`` rather than a payload on it because the two
        /// answer different questions. `robot` carries the `{"error": "…"}` string
        /// the `{type, command}` protocol uses, which has no code and never had one.
        /// This one carries JSON-RPC's, and the code is the whole point: `-32601`
        /// means the app's build has no such method and the control should go,
        /// while `-32000` with `not_running` means the app is gone — two different
        /// screens that were previously one string. ``errorDescription`` composes
        /// that same string, so nothing a user reads changes.
        case rpc(code: Int, message: String, reason: String?)
    }

    /// Not `private`: ``nextRPCID()`` lives beside the calls that spend it.
    var lastRPCID = 0
    private let channel: any RemoteDataChannel
    private let timeout: Duration
    /// The robot is the one that opens the channel, and only once a negotiation
    /// this side does not drive has got far enough — so a command issued before
    /// that pays for the relay round trip, ICE and DTLS too. On the same budget as
    /// a reply, a slow network reads as a robot that never answered.
    private let openingTimeout: Duration
    private var reader: Task<Void, Never>?
    /// One waiter per correlation token, which is all the wire can distinguish.
    private var waiting: [String: CheckedContinuation<Data, any Error>] = [:]
    /// Commands already in flight under the same token. Awaited in turn.
    private var queued: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Subscribers to unsolicited broadcasts, by the `type` they asked for. Keyed
    /// within a type so two consumers of the same stream can come and go
    /// independently.
    private var listeners: [String: [UUID: AsyncStream<Data>.Continuation]] = [:]

    public init(
        channel: any RemoteDataChannel,
        timeout: Duration = .seconds(10),
        openingTimeout: Duration = .seconds(30)
    ) {
        self.channel = channel
        self.timeout = timeout
        self.openingTimeout = openingTimeout
    }

    /// Which budget a command gets. Two different waits are being bounded here —
    /// "the channel is not open yet" and "the robot has not answered" — and only
    /// the second one says anything about the robot. Asked afresh each time rather
    /// than latched, because the opening wait comes back: an ICE failure replaces
    /// the peer under a session that has been up for hours, and the command after
    /// it sits out a whole negotiation again.
    private var currentTimeout: Duration {
        channel.isOpen ? timeout : openingTimeout
    }

    deinit { reader?.cancel() }

    /// Sends a command and waits for the robot's answer.
    @discardableResult
    public func perform(
        _ command: String,
        payload: [String: RemoteValue] = [:],
        correlation: Correlation = .echoedCommand
    ) async throws -> Data {
        startReading()
        let token = switch correlation {
        case .echoedCommand: command
        case let .replyKey(key): key
        case let .typed(type): type
        }
        await takeTurn(for: token)
        defer { yieldTurn(for: token) }
        // The turn can be a long wait behind another command of the same name, and a
        // caller that gave up meanwhile must not still put its command on the wire.
        try Task.checkCancellation()

        let text = try Self.encode(command, payload: payload)

        // A timer that fails the waiter, rather than a task group racing the
        // waiter against a sleep. The group would have to await both children
        // before it could exit, and a continuation nothing resumes has no way to
        // let it — one continuation with exactly four ways to be resumed (reply,
        // send failure, deadline, closed channel) has no such corner.
        let deadline = Task { [budget = currentTimeout] in
            try? await Task.sleep(for: budget)
            guard !Task.isCancelled else { return }
            self.expire(token)
        }
        defer { deadline.cancel() }

        let reply = try await awaitReply(to: token, sending: text)
        try Self.throwIfError(in: reply)
        return reply
    }

    /// The waiting half of ``call(_:params:timeout:)``, here because the state it
    /// touches is the actor's.
    func awaitRPCReply(id: Int, sending text: String, timeout: Duration?) async throws -> Data {
        startReading()
        let token = Self.rpcToken(id)
        let deadline = Task { [budget = timeout ?? currentTimeout] in
            try? await Task.sleep(for: budget)
            guard !Task.isCancelled else { return }
            self.expire(token)
        }
        defer { deadline.cancel() }
        return try await awaitReply(to: token, sending: text)
    }

    private func expire(_ token: String) {
        waiting.removeValue(forKey: token)?.resume(throwing: Failure.timedOut)
    }

    /// Sends a command and does not wait for an answer.
    ///
    /// Not an optimisation — for two commands it is the only correct shape.
    /// `subscribe_logs` is answered with *nothing*: `_start_log_subscription`
    /// replies only when the transport has no peer id, and otherwise just starts
    /// the journal task, so `perform` would sit out its whole budget and then
    /// report a robot that had in fact obeyed. Teleop is the other: at gesture
    /// rate a reply budget would serialise every frame behind the previous
    /// answer, because commands of one name take turns here by design.
    ///
    /// Anything the robot does send back arrives with no waiter registered and is
    /// dropped, which is what should happen to an answer nobody asked for.
    public func send(_ command: String, payload: [String: RemoteValue] = [:]) async throws {
        startReading()
        try await channel.send(Self.encode(command, payload: payload))
    }

    /// Sends a live frame only if the current peer can take it immediately.
    ///
    /// A control command may reasonably wait for a replacement peer; a teleop
    /// target may not. Queuing those at gesture rate makes the robot replay old
    /// motion after a reconnect, possibly after the controller has disappeared.
    @discardableResult
    public func sendIfOpen(
        _ command: String,
        payload: [String: RemoteValue] = [:]
    ) async throws -> Bool {
        startReading()
        return try await channel.sendIfOpen(Self.encode(command, payload: payload))
    }

    /// The unsolicited messages of one `type`.
    ///
    /// The robot broadcasts things nobody asked for — joint positions at 50 Hz,
    /// journal lines, update progress — and every one of them names a `type`, which
    /// is what subscribes to them here. A `type` does not mean "nobody asked",
    /// though: see ``Correlation/typed(_:)``, which claims a frame a caller is
    /// waiting for before the rest reach here.
    ///
    /// The stream ends when the channel does, so a console reading it learns that
    /// the session is over rather than sitting frozen with no explanation.
    public func broadcasts(ofType type: String) -> AsyncStream<Data> {
        startReading()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(500)
        )
        let id = UUID()
        listeners[type, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id, ofType: type) }
        }
        return stream
    }

    private func removeListener(_ id: UUID, ofType type: String) {
        listeners[type]?.removeValue(forKey: id)
        if listeners[type]?.isEmpty == true {
            listeners[type] = nil
        }
    }

    private static func encode(_ command: String, payload: [String: RemoteValue]) throws -> String {
        var body = payload
        body["type"] = .string(command)
        let encoded = try JSONCodec.daemon.encode(body)
        guard let text = String(bytes: encoded, encoding: .utf8) else {
            throw EncodingError.invalidValue(body, .init(
                codingPath: [],
                debugDescription: "command payload is not UTF-8"
            ))
        }
        return text
    }

    /// The same, with the answer decoded.
    @discardableResult
    public func perform<Reply: Decodable>(
        _ command: String,
        payload: [String: RemoteValue] = [:],
        correlation: Correlation = .echoedCommand,
        expecting _: Reply.Type
    ) async throws -> Reply {
        try await JSONCodec.daemon.decode(
            Reply.self,
            from: perform(command, payload: payload, correlation: correlation)
        )
    }

    private func awaitReply(to token: String, sending text: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            waiting[token] = continuation
            Task { [channel] in
                do {
                    try await channel.send(text)
                } catch {
                    self.resume(token, with: .failure(error))
                }
            }
        }
    }

    private func startReading() {
        guard reader == nil else { return }
        reader = Task { [channel] in
            for await text in channel.messages() {
                guard !Task.isCancelled else { return }
                deliver(text)
            }
            endReading()
        }
    }

    /// A finished stream cannot be restarted, so surviving one means asking the
    /// channel for another — which the next command does, once the reader is
    /// cleared out of its way. Without this the first close is permanent: replies
    /// keep arriving at a channel nobody reads, and every later command sits out
    /// its whole deadline.
    private func endReading() {
        reader = nil
        failAll(with: .closed)
        let open = listeners.values.flatMap(\.values)
        listeners = [:]
        for continuation in open {
            continuation.finish()
        }
    }

    /// The robot also broadcasts messages nobody asked for — joint positions at
    /// 50 Hz, journal lines, update progress — so a message has to be routed before
    /// it can be delivered, and the ones nobody subscribed to are dropped here.
    private func deliver(_ text: String) {
        let data = Data(text.utf8)
        guard let envelope = try? JSONCodec.daemon.decode(Envelope.self, from: data) else {
            // Dropped silently, the waiting caller sits out its whole budget and
            // reports the robot as quiet rather than the frame as unread.
            Self.log.error("unreadable frame on the data channel")
            return
        }
        switch envelope.route {
        case let .rpcReply(id):
            resume(Self.rpcToken(id), with: .success(data))
        case let .rpcNotification(method):
            yield(data, toListenersOf: method)
        case .rpcUnattributable:
            Self.log.error("json-rpc frame carrying neither an id nor a method")
        case let .typed(type):
            // Both, and in this order. Daemon 1.10.0 answers `get_imu` with the very
            // frame the robot also publishes unasked, so claiming it for the caller
            // alone starved anyone reading the broadcast — see `Correlation.typed`.
            yield(data, toListenersOf: type)
            if waiting[type] != nil {
                resume(type, with: .success(data))
            }
        case let .command(command):
            resume(command, with: .success(data))
        case let .keyed(keys):
            if let token = waiting.keys.first(where: keys.contains) {
                resume(token, with: .success(data))
            }
        }
    }

    private func yield(_ data: Data, toListenersOf type: String) {
        for continuation in listeners[type]?.values ?? [:].values {
            continuation.yield(data)
        }
    }

    private func resume(_ token: String, with result: Result<Data, any Error>) {
        guard let continuation = waiting.removeValue(forKey: token) else { return }
        continuation.resume(with: result)
    }

    private func failAll(with failure: Failure) {
        let pending = waiting.values
        waiting = [:]
        for continuation in pending {
            continuation.resume(throwing: failure)
        }
    }

    // MARK: One command of a name at a time

    private func takeTurn(for command: String) async {
        guard waiting[command] != nil || queued[command] != nil else {
            queued[command] = []
            return
        }
        await withCheckedContinuation { continuation in
            queued[command, default: []].append(continuation)
        }
    }

    private func yieldTurn(for command: String) {
        guard var line = queued[command], !line.isEmpty else {
            queued[command] = nil
            return
        }
        let next = line.removeFirst()
        queued[command] = line
        next.resume()
    }

    private static func throwIfError(in data: Data) throws {
        struct Reply: Decodable {
            let error: String?
        }
        if let error = try? JSONCodec.daemon.decode(Reply.self, from: data).error, !error.isEmpty {
            throw Failure.robot(error)
        }
    }
}
