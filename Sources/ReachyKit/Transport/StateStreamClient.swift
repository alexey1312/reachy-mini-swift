import Foundation
import ReachyJSON

/// Cumulative, privacy-safe health information for one state-stream subscription.
public struct StateStreamDiagnostics: Equatable, Sendable {
    public var receivedFrames = 0
    public var decodedFrames = 0
    public var decodeFailures = 0
    public var unsupportedFrames = 0
    public var lastFailureDescription: String?
    public var lastFailureAt: Date?

    public init() {}
}

/// One WebSocket frame and the diagnostics accumulated through that frame.
public struct StateStreamUpdate: Sendable {
    public let state: Components.Schemas.FullState?
    /// The same frame decoded by hand, for consumers that need the head pose as a
    /// matrix. See ``RobotStateFrame`` for why the generated type is not enough.
    public let frame: RobotStateFrame?
    public let diagnostics: StateStreamDiagnostics

    /// Public so a `RobotStateStreaming` implementation outside this module can
    /// yield one. The generated `state` defaults to nil because a producer that is
    /// not a socket has no `FullState` to offer — `RobotSceneModel` and
    /// `DirectionOfArrivalModel` both read `frame`, and the schema type is the
    /// health signal for a decode that did not happen here.
    public init(
        state: Components.Schemas.FullState? = nil,
        frame: RobotStateFrame?,
        diagnostics: StateStreamDiagnostics = .init()
    ) {
        self.state = state
        self.frame = frame
        self.diagnostics = diagnostics
    }
}

/// Streams the robot's full state from `ws://<host>:<port>/api/state/ws/full`.
///
/// The daemon sends 10 frames per second unless `Configuration.options` asks for
/// another rate. Reconnects forever with exponential backoff until the stream's
/// consumer cancels. Streams use `.bufferingNewest(1)`, so slow consumers always
/// observe the newest update.
public struct StateStreamClient: Sendable {
    public struct Configuration: Sendable {
        public var initialBackoff: Duration = .milliseconds(500)
        public var maxBackoff: Duration = .seconds(15)
        /// Empty by default, which reproduces the daemon's own defaults exactly.
        public var options = StateStreamOptions()
        public init() {}
    }

    public static let statePath = "/api/state/ws/full"

    let url: URL
    private let configuration: Configuration
    private let session: URLSession

    public init(
        address: RobotAddress,
        configuration: Configuration = .init(),
        session: URLSession = .shared
    ) throws {
        guard let url = address.webSocketURL(
            path: Self.statePath,
            queryItems: configuration.options.queryItems
        ) else {
            throw ReachyKitError.invalidAddress(address)
        }
        self.url = url
        self.configuration = configuration
        self.session = session
    }

    /// Latest-wins state plus cumulative frame diagnostics. A malformed frame is
    /// reported and skipped without reconnecting or terminating the stream.
    public func updates() -> AsyncStream<StateStreamUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: StateStreamUpdate.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task { [url, configuration, session] in
            var backoff = configuration.initialBackoff
            var diagnostics = StateStreamDiagnostics()
            while !Task.isCancelled {
                let socket = session.webSocketTask(with: url)
                socket.resume()
                // `receive()` does not observe task cancellation (see
                // `ConversationRPCClient.read`), so a cancelled consumer would
                // stay parked in it until the next 10 Hz frame — and exiting on
                // the `Task.isCancelled` check alone would leave the socket
                // open. The handler makes `receive()` throw; the unconditional
                // cancel below covers the checked exit.
                await withTaskCancellationHandler {
                    while !Task.isCancelled {
                        guard let message = try? await socket.receive() else { return }
                        diagnostics.receivedFrames += 1
                        let data: Data?
                        switch message {
                        case let .data(payload):
                            data = payload
                        case let .string(text):
                            data = Data(text.utf8)
                        @unknown default:
                            data = nil
                            diagnostics.unsupportedFrames += 1
                            diagnostics.lastFailureDescription = "Unsupported WebSocket frame type"
                            diagnostics.lastFailureAt = Date()
                        }

                        guard let data else {
                            continuation.yield(.init(state: nil, frame: nil, diagnostics: diagnostics))
                            continue
                        }
                        // Decoded separately and never folded into diagnostics: the
                        // generated schema stays the health signal, so a viewer-only
                        // decode problem cannot masquerade as a broken stream.
                        let frame = try? JSONCodec.daemon.decode(RobotStateFrame.self, from: data)
                        do {
                            let state = try JSONCodec.daemon.decode(Components.Schemas.FullState.self, from: data)
                            diagnostics.decodedFrames += 1
                            continuation.yield(.init(state: state, frame: frame, diagnostics: diagnostics))
                            backoff = configuration.initialBackoff
                        } catch {
                            diagnostics.decodeFailures += 1
                            diagnostics.lastFailureDescription = Self.failureDescription(error)
                            diagnostics.lastFailureAt = Date()
                            continuation.yield(.init(state: nil, frame: frame, diagnostics: diagnostics))
                        }
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
                socket.cancel(with: .goingAway, reason: nil)
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, configuration.maxBackoff)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Compatibility wrapper for consumers interested only in valid states.
    public func states() -> AsyncStream<Components.Schemas.FullState> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Components.Schemas.FullState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task {
            for await update in updates() {
                if let state = update.state {
                    continuation.yield(state)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func failureDescription(_ error: any Error) -> String {
        String(describing: error).prefix(240).description
    }
}
