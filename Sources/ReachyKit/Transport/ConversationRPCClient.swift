import Foundation
import ReachyJSON

/// Observes Conversation App 1.0 over its JSON-RPC 2.0 WebSocket.
///
/// The app serves this itself, on a port of its own that the daemon only reports
/// (``RobotApp/customAppPort``). That makes this direct LAN path available while
/// the supported daemon baseline is still 1.9.0; the daemon-side WebRTC relay,
/// which carries the same frames, arrived later.
public struct ConversationRPCClient: Sendable {
    public struct Configuration: Sendable {
        /// Where to knock when the daemon named no port. Conversation App 1.0
        /// declares `http://0.0.0.0:7860/`, and a fork copying its `main.py`
        /// inherits that, so the app being reachable does not depend on the
        /// daemon having kept its metadata.
        public var fallbackPort = 7860
        public var initialBackoff: Duration = .milliseconds(500)
        public var maxBackoff: Duration = .seconds(15)

        public init() {}
    }

    public static let rpcPath = "/rpc"

    let url: URL
    private let configuration: Configuration
    private let session: URLSession

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

    /// Semantic turn notifications, reconnecting until the consumer cancels.
    ///
    /// Other JSON-RPC notifications and replies share the socket and are ignored.
    /// A future state is carried as ``ConversationTurn/unknown(_:)`` rather than
    /// ending the stream.
    public func turns() -> AsyncStream<ConversationTurn> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConversationTurn.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task { [url, configuration, session] in
            var backoff = configuration.initialBackoff
            while !Task.isCancelled {
                let socket = session.webSocketTask(with: url)
                socket.resume()
                await Self.read(from: socket, into: continuation) {
                    backoff = configuration.initialBackoff
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

    /// Pumps one socket until it fails or the consumer goes away.
    ///
    /// **`URLSessionWebSocketTask.receive()` does not observe task cancellation.**
    /// It is the compiler's bridge over the completion-handler API, so a cancelled
    /// task stays parked in it until the *robot* says something — and the dock
    /// tears this observer down on every backgrounding and every app switch, so
    /// that is a socket left open each time, not a corner case. Cancelling the
    /// socket by hand is what makes `receive()` throw and the loop end.
    private static func read(
        from socket: URLSessionWebSocketTask,
        into continuation: AsyncStream<ConversationTurn>.Continuation,
        onFrame: () -> Void
    ) async {
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { return }
                let text: String? = switch message {
                case let .string(text): text
                case let .data(data): String(data: data, encoding: .utf8)
                @unknown default: nil
                }
                if let text, let turn = Self.turn(in: text) {
                    continuation.yield(turn)
                }
                onFrame()
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    static func turn(in frame: String) -> ConversationTurn? {
        struct Notification: Decodable {
            struct Parameters: Decodable {
                let state: ConversationTurn?
            }

            let method: String?
            let params: Parameters?
        }

        guard let data = frame.data(using: .utf8),
              let notification = try? JSONCodec.daemon.decode(Notification.self, from: data),
              notification.method == "conversation.turn"
        else { return nil }
        return notification.params?.state
    }
}
