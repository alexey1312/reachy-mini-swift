import Foundation
import ReachyJSON

/// The robot's pose over the relay, pushed on its own channel.
///
/// Daemon 1.10.0 writes the state snapshot to a second data channel at about
/// 30 Hz once asked, which is what this reads. It replaces polling `get_state`
/// (``RemoteStateStream``) and is better in the way that matters over somebody's
/// internet: nothing waits on a round trip, so a slow link loses frames instead of
/// stuttering through them.
///
/// **The channel is unordered and lossy by design**, which is why `seq` is read
/// rather than ignored: a frame that arrives after a newer one is stale, not new,
/// and drawing it would jerk the model backwards.
public struct RemotePoseStream: RobotStateStreaming {
    private let connection: RemoteRobotConnection
    private let channel: any RemoteDataChannel

    public init(connection: RemoteRobotConnection, channel: any RemoteDataChannel) {
        self.connection = connection
        self.channel = channel
    }

    /// The options are read for nothing here, and that is the daemon's choice:
    /// the publisher runs at its own rate and takes no arguments. A viewer asking
    /// for 20 Hz gets 30 and is none the worse for it.
    public func updates(_: StateStreamOptions) -> AsyncStream<StateStreamUpdate> {
        AsyncStream { continuation in
            let task = Task { [connection, channel] in
                // Subscribed before the stream is read, not after: the daemon
                // starts publishing the moment it is asked, and a reader set up
                // afterwards would drop the first frames on the floor.
                try? await connection.subscribeToPose()
                defer { Task { try? await connection.unsubscribeFromPose() } }

                var diagnostics = StateStreamDiagnostics()
                var newest = Int.min
                for await text in channel.messages() {
                    guard !Task.isCancelled else { break }
                    diagnostics.receivedFrames += 1
                    guard let frame = try? JSONCodec.daemon.decode(
                        RemotePoseFrame.self,
                        from: Data(text.utf8)
                    ) else {
                        diagnostics.decodeFailures += 1
                        continue
                    }
                    guard frame.seq > newest else {
                        // Out of order, which this channel is allowed to be.
                        diagnostics.unsupportedFrames += 1
                        continue
                    }
                    newest = frame.seq
                    diagnostics.decodedFrames += 1
                    continuation.yield(StateStreamUpdate(
                        frame: frame.state.frame,
                        diagnostics: diagnostics
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
