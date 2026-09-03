import Foundation
import ReachyJSON

/// A robot app's JSON-RPC surface over its own WebSocket, on the LAN.
///
/// The app serves this itself, on a port of its own that the daemon only reports
/// (``RobotApp/customAppPort``). That makes this direct path available while the
/// supported daemon baseline is still 1.9.0; the daemon-side WebRTC relay, which
/// carries the same frames, arrived later and is ``RemoteConversation``.
///
/// **One socket, multiplexed** — requests and notifications share it, correlated by
/// JSON-RPC `id`. It used to be a socket per call, and the file that did it named the
/// trigger for changing: *"Multiplexing onto `turns()` is what to do if something
/// here ever needs a call per frame rather than per tap."* A transcript, a composer
/// and two pickers are that. Push-to-talk is the sharpest case — a handshake between
/// letting go of a button and the robot ceasing to listen is latency nobody can
/// explain away.
///
/// The state below is deliberately the same five things, under the same names, as
/// ``RemoteControlChannel``: a reader who knows one knows this. What differs is forced
/// by the transport — ids are `Int` because this client mints them, there is no
/// `Correlation` because every frame here is JSON-RPC and the id is the whole of it,
/// and there is a reconnect loop because a socket to an app process dies where a data
/// channel to the daemon does not.
///
/// **The socket follows demand**, so nothing here needs a lifetime rule: it opens when
/// somebody is listening or calling and closes when nobody is. A screen that holds one
/// channel pays for one connection; a dock tapping a button pays for one per tap, as
/// it always did; and a channel somebody abandoned without closing holds nothing.
public actor ConversationRPCClient: ConversationChannel {
    public struct Configuration: Sendable {
        /// Where to knock when the daemon named no port. Conversation App 1.0
        /// declares `http://0.0.0.0:7860/`, and a fork copying its `main.py`
        /// inherits that, so the app being reachable does not depend on the
        /// daemon having kept its metadata.
        public var fallbackPort = 7860
        public var initialBackoff: Duration = .milliseconds(500)
        public var maxBackoff: Duration = .seconds(15)
        /// How long one request waits for its reply. Generous because the app is
        /// answering from inside a conversation turn, not from an idle loop.
        public var replyTimeout: Duration = .seconds(10)

        public init() {}
    }

    public static let rpcPath = "/rpc"

    /// `nonisolated` because they are immutable and read from outside: the URL is
    /// what the shape tests assert on, and the configuration is read inside a detached
    /// deadline. An actor's isolation is for what changes.
    nonisolated let url: URL
    nonisolated let configuration: Configuration
    nonisolated let session: URLSession

    private var socket: URLSessionWebSocketTask?
    private var pump: Task<Void, Never>?
    /// One waiter per JSON-RPC id.
    private var waiting: [Int: CheckedContinuation<Data, any Error>] = [:]
    /// Subscribers to everything the app pushes.
    private var listeners: [UUID: AsyncStream<ConversationEvent>.Continuation] = [:]
    /// Frames written before a socket existed. Flushed when one does, so a call made
    /// the instant a channel is built does not have to fail or poll.
    private var outbox: [String] = []
    private var nextID = 0
    /// Calls awaiting a reply. Part of demand: a socket must not be released out from
    /// under one, and a lone call must be able to open one with nobody listening.
    private var inFlight = 0
    /// Whether the socket now open has ever produced a frame.
    ///
    /// The first frame is the only proof this socket reached the app — `resume()`
    /// returns before the handshake, so announcing an opening there would bracket a
    /// gap that never closed. It is also what a successful backoff reset is keyed on:
    /// a connection that answered is what proves the backoff should start over, not
    /// one that was merely attempted.
    private var socketHasDelivered = false

    /// - Parameters:
    ///   - address: the robot, whose host this keeps and whose port it replaces.
    ///   - port: the app's own port. Nil falls back to
    ///     ``Configuration/fallbackPort``.
    public init(
        address: RobotAddress,
        port: Int? = nil,
        configuration: Configuration = .init(),
        session: URLSession = .shared
    ) throws {
        let appAddress = RobotAddress(host: address.host, port: port ?? configuration.fallbackPort)
        guard let url = appAddress.webSocketURL(path: Self.rpcPath) else {
            throw ReachyKitError.invalidAddress(address)
        }
        self.url = url
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Subscribing

    public nonisolated func events() -> AsyncStream<ConversationEvent> {
        // `makeStream`, never `AsyncStream { continuation in … }`. The builder form is
        // what a closure capturing the escaping continuation can nest inside, and that
        // shape sends `ClosureLifetimeFixup` into a dominator walk it does not return
        // from — twenty minutes of one core with no diagnostic, which reads as a hang
        // in whatever is under test. See `RemoteControlChannelTests`' own note.
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConversationEvent.self,
            // Not `.bufferingNewest(1)`, which is what the turn-only stream used and
            // was right for a caption. There is no transcript history anywhere on the
            // robot, so a line dropped here is gone for good. Sixty-four is about four
            // seconds of the 15 Hz meter — generous for a consumer appending to an
            // array, and bounded so a stalled one cannot accumulate.
            bufferingPolicy: .bufferingNewest(64)
        )
        let id = UUID()
        Task { await self.subscribe(id, continuation) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func subscribe(_ id: UUID, _ continuation: AsyncStream<ConversationEvent>.Continuation) {
        listeners[id] = continuation
        startPumpIfNeeded()
    }

    private func unsubscribe(_ id: UUID) {
        listeners.removeValue(forKey: id)?.finish()
        releaseIfIdle()
    }

    public func close() async {
        pump?.cancel()
        pump = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        outbox.removeAll()
        failAllWaiters()
        let open = listeners.values
        listeners = [:]
        for continuation in open {
            continuation.finish()
        }
    }

    // MARK: - Calling

    /// One JSON-RPC request, answered by its `id`.
    ///
    /// The deadline is a timer that fails **this** waiter, never one that cancels the
    /// socket. On a socket of its own that distinction did not matter; here it is the
    /// difference between one call giving up and every other call in flight dying with
    /// it. (The old code's own note records the other half of the hazard: a `try?`-ed
    /// `Task.sleep` reports a cancelled sleep exactly like an elapsed one.)
    @discardableResult
    func call(_ method: String, params: [String: RemoteValue] = [:]) async throws -> Data {
        inFlight += 1
        defer {
            inFlight -= 1
            releaseIfIdle()
        }
        nextID += 1
        let id = nextID
        let text = try Self.encode(method: method, params: params, id: id)
        startPumpIfNeeded()

        let deadline = Task { [configuration] in
            try? await Task.sleep(for: configuration.replyTimeout)
            guard !Task.isCancelled else { return }
            await self.expire(id)
        }
        defer { deadline.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            write(text)
        }
    }

    func call<Reply: Decodable & Sendable>(
        _ method: String,
        params: [String: RemoteValue] = [:],
        expecting _: Reply.Type
    ) async throws -> Reply {
        let data = try await call(method, params: params)
        do {
            return try JSONCodec.daemon.decode(RPCResult<Reply>.self, from: data).result
        } catch {
            // The app answered something this build cannot read. `.unreachable` is the
            // honest report: the call did not do what was asked, and no reason came
            // back that a screen could put in front of somebody.
            throw ConversationFailure.unreachable
        }
    }

    private func expire(_ id: Int) {
        waiting.removeValue(forKey: id)?.resume(throwing: ConversationFailure.timedOut)
    }

    /// Sends now if there is a socket, and otherwise when there is one. Queuing rather
    /// than failing is what lets a caller build a channel and call on it in the same
    /// breath — the screen's priming reads all do exactly that.
    private func write(_ text: String) {
        guard let socket else {
            outbox.append(text)
            return
        }
        Task {
            do {
                try await socket.send(.string(text))
            } catch {
                await self.dropSocket()
            }
        }
    }

    private func flushOutbox(on socket: URLSessionWebSocketTask) async {
        let pending = outbox
        outbox = []
        for text in pending {
            try? await socket.send(.string(text))
        }
    }

    // MARK: - The socket

    private var hasDemand: Bool {
        !listeners.isEmpty || inFlight > 0
    }

    private func startPumpIfNeeded() {
        guard pump == nil, hasDemand else { return }
        pump = Task { await self.run() }
    }

    /// Cancels the socket the moment nothing needs it. Called at the end of every call
    /// and on every unsubscribe, so an abandoned channel costs nothing even if
    /// ``close()`` was never reached.
    private func releaseIfIdle() {
        guard !hasDemand else { return }
        pump?.cancel()
        pump = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        outbox.removeAll()
    }

    private func run() async {
        var backoff = configuration.initialBackoff
        while !Task.isCancelled, hasDemand {
            let socket = session.webSocketTask(with: url)
            self.socket = socket
            socket.resume()
            await flushOutbox(on: socket)

            socketHasDelivered = false
            await read(from: socket)

            socket.cancel(with: .goingAway, reason: nil)
            if self.socket === socket {
                self.socket = nil
            }
            // A reply cannot outlive its socket, so waiting any longer would spend a
            // caller's whole budget learning what is already known.
            failAllWaiters()
            if socketHasDelivered {
                yield(.closed)
                backoff = configuration.initialBackoff
            }

            guard !Task.isCancelled, hasDemand else { break }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, configuration.maxBackoff)
        }
        pump = nil
    }

    private func dropSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Pumps one socket until it fails or nothing needs it.
    ///
    /// **`URLSessionWebSocketTask.receive()` does not observe task cancellation.**
    /// It is the compiler's bridge over the completion-handler API, so a cancelled
    /// task stays parked in it until the *robot* says something — and this observer is
    /// torn down on every backgrounding and every app switch, so that is a socket left
    /// open each time, not a corner case. Cancelling the socket by hand is what makes
    /// `receive()` throw and the loop end.
    private func read(from socket: URLSessionWebSocketTask) async {
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { return }
                if !socketHasDelivered {
                    socketHasDelivered = true
                    yield(.opened)
                }
                let text: String? = switch message {
                case let .string(text): text
                case let .data(data): String(data: data, encoding: .utf8)
                @unknown default: nil
                }
                guard let text else { continue }
                deliver(Data(text.utf8))
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    /// A frame is either somebody's reply or something the app said. `Envelope` is what
    /// tells them apart, and it is the same reader the relay arm uses — including its
    /// tolerance for a quoted id, which matters because JSON-RPC permits one and the
    /// app's own web client sends `"ui-1"`.
    private func deliver(_ data: Data) {
        guard let envelope = try? JSONCodec.daemon.decode(Envelope.self, from: data) else { return }
        switch envelope.route {
        case let .rpcReply(id):
            resume(id, with: data)
        case .rpcNotification:
            guard let event = ConversationEvent.decoded(from: data) else { return }
            yield(event)
        case .rpcUnattributable, .typed, .command, .keyed:
            return
        }
    }

    private func resume(_ id: Int, with data: Data) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        do {
            try Self.throwIfError(in: data)
            continuation.resume(returning: data)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func yield(_ event: ConversationEvent) {
        for continuation in listeners.values {
            continuation.yield(event)
        }
    }

    private func failAllWaiters() {
        let pending = waiting.values
        waiting = [:]
        for continuation in pending {
            continuation.resume(throwing: ConversationFailure.unreachable)
        }
    }

    // MARK: - Wire

    private static func encode(method: String, params: [String: RemoteValue], id: Int) throws -> String {
        let body: [String: RemoteValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object(params),
            "id": .number(Double(id)),
        ]
        guard let text = try String(data: JSONCodec.daemon.encode(body), encoding: .utf8) else {
            throw ConversationFailure.unreachable
        }
        return text
    }

    /// The app's refusals, in the vocabulary both transports share.
    private static func throwIfError(in data: Data) throws {
        guard let failure = try? JSONCodec.daemon.decode(Reply.self, from: data).error else { return }
        throw ConversationFailure(
            code: failure.code,
            message: failure.message ?? "The app refused the call",
            reason: failure.data?.reason
        )
    }

    struct Reply: Decodable {
        struct Failure: Decodable {
            struct Detail: Decodable {
                let reason: String?
            }

            let code: Int?
            let message: String?
            let data: Detail?
        }

        let error: Failure?
    }
}

/// The `result` half of a JSON-RPC reply.
///
/// Module-wide rather than private to either arm: the LAN socket and the daemon's
/// relay carry the same JSON-RPC, so two copies of this would be two chances to read
/// one wire format differently.
struct RPCResult<Value: Decodable>: Decodable {
    let result: Value
}
