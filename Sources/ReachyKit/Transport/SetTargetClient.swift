import Foundation

/// Live teleop: streams `FullBodyTarget` frames to `ws://…/api/move/ws/set_target`.
///
/// `send(_:)` sets a *goal*; a ticker walks the emitted pose toward it under
/// `TargetSlewLimiter` and stops transmitting once it arrives. Every writer in the
/// app funnels through here, so none of them — a joystick release, a slider jump,
/// "Reset to neutral" — can put a step on the wire.
///
/// The daemon clamps all safety limits server-side and ignores targets while a
/// recorded move is running. The server's error replies are drained and kept in
/// `lastServerError`.
public actor SetTargetClient {
    public static let path = "/api/move/ws/set_target"

    /// The target moved to `TeleopTarget` when the data channel grew a second way
    /// to send one. Kept as a name so the screens and tests that spell it this way
    /// are unchanged.
    public typealias Target = TeleopTarget

    public private(set) var lastServerError: String?

    private let url: URL
    private let session: URLSession
    private let tickInterval: Duration
    private var limiter: TargetSlewLimiter
    private var socket: URLSessionWebSocketTask?
    private var drainTask: Task<Void, Never>?
    private var pacerTask: Task<Void, Never>?
    private var goal = Target()
    private var emitted = Target()

    public init(
        address: RobotAddress,
        tickInterval: Duration = .milliseconds(33),
        limiter: TargetSlewLimiter = TargetSlewLimiter(),
        session: URLSession = .shared
    ) throws {
        guard let url = address.webSocketURL(path: Self.path) else {
            throw ReachyKitError.invalidAddress(address)
        }
        self.url = url
        self.session = session
        self.tickInterval = tickInterval
        self.limiter = limiter
    }

    public func connect() {
        guard socket == nil else { return }
        let socket = session.webSocketTask(with: .toDaemon(url))
        socket.resume()
        self.socket = socket
        drainTask = Task { [weak self] in
            while let self, let socket = await self.socket {
                guard let message = try? await socket.receive() else { break }
                if case let .string(text) = message {
                    await record(serverError: text)
                }
            }
        }
        let interval = tickInterval
        pacerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.tick()
            }
        }
    }

    public func disconnect() {
        pacerTask?.cancel()
        pacerTask = nil
        drainTask?.cancel()
        drainTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    public func setLimiter(_ limiter: TargetSlewLimiter) {
        self.limiter = limiter
    }

    /// Aims at `target`. Nothing goes out here — the pacer decides when and how
    /// fast, which is what makes every command path smooth by construction.
    public func send(_ target: Target) {
        goal = target
    }

    private func tick() async {
        guard let socket, emitted != goal else { return }
        let next = limiter.next(current: emitted, goal: goal, dt: tickInterval)
        emitted = limiter.hasConverged(next, to: goal) ? goal : next
        guard let text = String(bytes: Self.encode(emitted), encoding: .utf8) else { return }
        try? await socket.send(.string(text))
    }

    private func record(serverError text: String) {
        lastServerError = text
    }

    /// Wire format: `FullBodyTarget` JSON, head pose as flat XYZRPY.
    static func encode(_ target: Target) -> Data {
        let payload: [String: Any] = [
            "target_head_pose": [
                "x": target.x, "y": target.y, "z": target.z,
                "roll": target.roll, "pitch": target.pitch, "yaw": target.yaw,
            ],
            // The daemon names this tuple `[right, left]`; keep the Swift model
            // physically named and perform the wire-order conversion here.
            "target_antennas": [target.antennaRight, target.antennaLeft],
            "target_body_yaw": target.bodyYaw,
        ]
        // ponytail: JSONSerialization over generated FullBodyTarget — the anyOf
        // head-pose payload encodes asymmetrically; a flat dict is the wire truth
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

/// Every requirement is already satisfied verbatim — an actor's isolated method
/// meets an `async` one.
extension SetTargetClient: TeleopChannel {}

extension RobotConnection: TeleopClient {
    public nonisolated func makeTeleop() throws -> any TeleopChannel {
        try SetTargetClient(address: address)
    }
}
