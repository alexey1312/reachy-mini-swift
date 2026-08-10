import Foundation

/// The client half of the Hugging Face relay — how this app reaches a robot that
/// is not on the same network.
///
/// The same signaling protocol the robot serves on port 8443, over a different
/// transport: a server-sent-event stream down, HTTP POSTs up. Central is a
/// Hugging Face Space, and it authenticates every call with the user's own token,
/// which is what makes a robot visible to its owner and to nobody else.
///
/// Every constant here is the robot's, from `central_signaling_relay.py`, so both
/// ends give up and retry on the same schedule.
public actor CentralRelayClient {
    public struct Configuration: Sendable {
        /// Overridable for a fork or a staging Space — the daemon reads the same
        /// value from `REACHY_CENTRAL_URL`.
        public var baseURL: URL
        /// What the robot's owner sees holding their robot while this session is
        /// up, so it names the app rather than the device.
        public var clientName: String
        /// The robot allows 60 s of silence before calling the stream dead;
        /// central sends a keepalive well inside that.
        ///
        /// No reconnect schedule lives here: this client makes one attempt per
        /// `events()` stream, and retrying belongs to the consumer
        /// (`RemoteRobotLink`), which knows whether a failure is worth it.
        public var readTimeout: Duration

        public init(
            baseURL: URL = CentralRelayClient.defaultBaseURL,
            clientName: String = "Reachy Mini",
            readTimeout: Duration = .seconds(60)
        ) {
            self.baseURL = baseURL
            self.clientName = clientName
            self.readTimeout = readTimeout
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// This app holds no token. Nothing to retry — the user signs in first.
        case noToken
        /// Central refused the token. Also nothing to retry: the same token will
        /// be refused again.
        case unauthorized
        /// 1200 requests a minute per token. Retrying at once turns a limit into
        /// a ban.
        case rateLimited
        case http(Int)
    }

    /// One robot as the event stream lists it. Thinner than `CentralRobot`, which
    /// is what the REST route serves: the stream carries only what changed.
    public struct Producer: Equatable, Sendable {
        public let peerID: String
        public let name: String?
        public let isBusy: Bool
        public let activeApp: String?
    }

    /// Domain-level, like `CameraSignalingClient.Event`: the wire type stays an
    /// implementation detail of this module.
    public enum Event: Equatable, Sendable {
        case connected(peerID: String)
        case producers([Producer])
        /// The robot is the offerer over the relay too.
        case offer(sessionID: String, sdp: String)
        case remoteCandidate(sessionID: String, candidate: String, sdpMLineIndex: Int32, sdpMid: String?)
        /// `reason` is central's — `local_app_started`, `install_id_takeover` and
        /// the rest — and is what a screen turns into an apology.
        case sessionEnded(sessionID: String, reason: String?)
        case failed(Failure)
        /// The stream ended and can be retried, unless a `.failed` came first.
        case disconnected
    }

    /// What `startSession` came back with. A refusal is an answer, not an error:
    /// somebody else is simply using the robot.
    public enum SessionOutcome: Equatable, Sendable {
        case started(sessionID: String)
        case rejected(reason: String, activeApp: String?)
    }

    public static let defaultBaseURL = URL(string: "https://pollen-robotics-reachy-mini-central.hf.space")!

    private let configuration: Configuration
    private let session: URLSession
    private let token: @Sendable () async -> String?

    /// The token is fetched per request rather than held: it can be renewed or
    /// revoked while a stream is open, and a copy kept here would outlive both.
    public init(
        configuration: Configuration = Configuration(),
        session: URLSession = .shared,
        token: @escaping @Sendable () async -> String?
    ) {
        self.configuration = configuration
        self.session = session
        self.token = token
    }

    /// One pass over `GET /events`. Ends with `.failed` for anything terminal and
    /// `.disconnected` when the stream simply stopped.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(256))
        let task = Task { await run(continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Asks a robot for a session. Central answers in the body of this very POST
    /// rather than over the stream, so the outcome is returned here.
    public func startSession(with peerID: String) async throws -> SessionOutcome {
        switch try await send(.startSession(peerID: peerID)) {
        case let .sessionStarted(_, sessionID):
            .started(sessionID: sessionID)
        case let .sessionRejected(reason, activeApp):
            .rejected(reason: reason, activeApp: activeApp)
        case let .endSession(_, reason):
            // Central refuses either way round; both mean "not now".
            .rejected(reason: reason ?? "unavailable", activeApp: nil)
        default:
            throw Failure.http(200)
        }
    }

    public func answer(sessionID: String, sdp: String) async throws {
        try await send(.sdp(sessionID: sessionID, type: "answer", sdp: sdp))
    }

    public func send(
        candidate: String,
        sdpMLineIndex: Int32,
        sdpMid: String?,
        sessionID: String
    ) async throws {
        try await send(.ice(
            sessionID: sessionID,
            candidate: candidate,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid
        ))
    }

    public func endSession(_ sessionID: String, reason: String? = nil) async throws {
        try await send(.endSession(sessionID: sessionID, reason: reason))
    }

    /// Sends one signaling message. Central answers in the body of this very POST,
    /// so the reply is returned rather than waited for on the stream.
    @discardableResult
    func send(_ message: SignalingMessage) async throws -> SignalingMessage? {
        var request = try await authorized(path: "/send")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(message)

        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        // An acknowledgement (`{"status":"ok"}`) is not a signaling message, and
        // not an error either.
        return try? JSONDecoder().decode(SignalingMessage.self, from: data)
    }

    /// The robots central can see for this token. Presence in the list *is* the
    /// online signal: central sweeps a peer whose lease lapsed.
    public func robots() async throws -> [CentralRobot] {
        struct Response: Decodable {
            let robots: [CentralRobot]
        }
        let (data, response) = try await session.data(for: authorized(path: "/api/robot-status"))
        try Self.check(response)
        return try JSONDecoder().decode(Response.self, from: data).robots
    }

    /// The one route central serves without a token.
    public func isReachable() async -> Bool {
        guard let url = URL(string: "/health", relativeTo: configuration.baseURL) else { return false }
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - The stream

    private func run(_ continuation: AsyncStream<Event>.Continuation) async {
        defer { continuation.finish() }

        var request: URLRequest
        do {
            request = try await authorized(path: "/events")
        } catch let failure as Failure {
            continuation.yield(.failed(failure))
            return
        } catch {
            continuation.yield(.failed(.http(-1)))
            return
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Double(configuration.readTimeout.components.seconds)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Self.check(response)
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                guard let message = Self.message(in: line) else { continue }
                if case let .welcome(peerID) = message {
                    // Announce *before* reporting the connection, the way the
                    // robot's own relay registers as a producer before flipping to
                    // CONNECTED: otherwise an observer sees a live connection while
                    // central still knows nothing about this peer. Central also
                    // evicts peers with no recent inbound traffic, and the name
                    // sent here is what the robot's owner sees holding their robot.
                    // Dropped rather than reported: the stream itself is already up,
                    // and every later call goes through the same POST — a failure
                    // here surfaces on the next one with something to say about it,
                    // where failing the connection now would throw away a live
                    // stream over a name.
                    _ = try? await send(.setPeerStatus(roles: ["listener"], name: configuration.clientName))
                    continuation.yield(.connected(peerID: peerID))
                    continue
                }
                if let event = Self.event(for: message) {
                    continuation.yield(event)
                }
            }
            continuation.yield(.disconnected)
        } catch let failure as Failure {
            continuation.yield(.failed(failure))
        } catch {
            continuation.yield(.disconnected)
        }
    }

    /// Everything else on the stream is either a domain event or noise this
    /// client has no use for (`peerStatusChanged` for peers we never asked about,
    /// `sessionStateChanged`, central's own `error` advisories).
    static func event(for message: SignalingMessage) -> Event? {
        switch message {
        case let .producerList(producers):
            .producers(producers.map {
                Producer(peerID: $0.id, name: $0.name, isBusy: $0.isBusy, activeApp: $0.activeApp)
            })
        case let .sdp(sessionID, _, sdp):
            .offer(sessionID: sessionID, sdp: sdp)
        case let .ice(sessionID, candidate, sdpMLineIndex, sdpMid):
            .remoteCandidate(
                sessionID: sessionID,
                candidate: candidate,
                sdpMLineIndex: sdpMLineIndex,
                sdpMid: sdpMid
            )
        case let .endSession(sessionID, reason):
            .sessionEnded(sessionID: sessionID, reason: reason)
        default:
            nil
        }
    }

    /// One SSE line. Anything but `data:` is framing, and a `data:` line that is
    /// not JSON is central's keepalive.
    static func message(in line: String) -> SignalingMessage? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty,
              let message = try? JSONDecoder().decode(SignalingMessage.self, from: Data(payload.utf8))
        else { return nil }
        // An empty candidate is WebRTC's end-of-candidates marker, and
        // `RTCIceCandidate` throws on it — dropping it here keeps that out of the
        // media layer entirely.
        if case let .ice(_, candidate, _, _) = message, candidate.isEmpty {
            return nil
        }
        return message
    }

    private func authorized(path: String) async throws -> URLRequest {
        guard let token = await token() else { throw Failure.noToken }
        guard let url = URL(string: path, relativeTo: configuration.baseURL) else {
            throw Failure.http(-1)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.http(-1) }
        switch http.statusCode {
        case 200 ..< 300: return
        case 401, 403: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        case let code: throw Failure.http(code)
        }
    }
}
