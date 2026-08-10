import Foundation

/// Streams daemon log lines from `ws://…/logs/ws/daemon`.
///
/// The daemon tails `journalctl -u reachy-mini-daemon` — plain text lines
/// (short-iso). The router is mounted at the app ROOT (not under `/api`) and
/// only with `--wireless-version`: real robot only, the simulator rejects the
/// upgrade with HTTP 403 (verified against daemon main.py and a live sim).
/// Same reconnect-with-backoff shape as `StateStreamClient`.
public struct LogStreamClient: Sendable {
    public static let path = "/logs/ws/daemon"

    private let url: URL
    private let session: URLSession

    public init(address: RobotAddress, session: URLSession = .shared) throws {
        guard let url = address.webSocketURL(path: Self.path) else {
            throw ReachyKitError.invalidAddress(address)
        }
        self.url = url
        self.session = session
    }

    /// Log lines; never throws, ends only on cancellation. Reconnects with backoff.
    public func lines() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(500)
        )
        let task = Task { [url, session] in
            var backoff = Duration.milliseconds(500)
            while !Task.isCancelled {
                let socket = session.webSocketTask(with: url)
                socket.resume()
                await Self.read(from: socket, into: continuation) {
                    backoff = .milliseconds(500)
                }
                socket.cancel(with: .goingAway, reason: nil)
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(15))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Pumps one socket until it fails or the consumer goes away.
    ///
    /// `URLSessionWebSocketTask.receive()` does not observe task cancellation
    /// (`ConversationRPCClient.read` documents why): a dismissed log console
    /// would stay parked in it until the next journal line, holding the socket
    /// open at line rate for the life of the app. Cancelling the socket by
    /// hand is what makes `receive()` throw and the loop end.
    private static func read(
        from socket: URLSessionWebSocketTask,
        into continuation: AsyncStream<String>.Continuation,
        onFrame: () -> Void
    ) async {
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { return }
                if case let .string(text) = message {
                    continuation.yield(text)
                    onFrame()
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }
}
