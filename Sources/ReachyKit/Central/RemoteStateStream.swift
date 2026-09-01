import Foundation

/// The robot's live pose over the relay, polled rather than pushed.
///
/// There is no socket to open here and no query string to ask for fields: the
/// data channel answers `get_state` with the whole snapshot, so the option set
/// decides only how often to ask.
///
/// **The fallback, not the first choice.** ``RemotePoseStream`` reads the same
/// snapshot off the `pose` channel daemon 1.10.0 pushes it on, which costs no
/// round trip per frame. This is what serves a daemon that opens no such channel,
/// and it is enough because `RemoteControlChannel` queues per command name: a poll
/// waits only behind another poll, never in front of a wake-up.
public struct RemoteStateStream: RobotStateStreaming {
    private let connection: RemoteRobotConnection
    /// The ceiling the viewer's 20 Hz is clamped to. Every frame is a round trip
    /// over somebody's internet rather than a datagram on the same LAN, and a
    /// model redrawn ten times a second already reads as continuous.
    private let maximumFrequency: Double

    public init(connection: RemoteRobotConnection, maximumFrequency: Double = 10) {
        self.connection = connection
        self.maximumFrequency = maximumFrequency
    }

    public func updates(_ options: StateStreamOptions) -> AsyncStream<StateStreamUpdate> {
        let interval = Duration.seconds(1 / max(1, min(options.frequency ?? maximumFrequency, maximumFrequency)))
        return AsyncStream { continuation in
            let task = Task { [connection] in
                var diagnostics = StateStreamDiagnostics()
                while !Task.isCancelled {
                    do {
                        let frame = try await connection.stateFrame()
                        diagnostics.receivedFrames += 1
                        if frame != nil {
                            diagnostics.decodedFrames += 1
                        } else {
                            // A robot whose backend is down answers the command and
                            // carries no pose. Counted apart from a decode failure,
                            // which is this client not understanding the answer.
                            diagnostics.unsupportedFrames += 1
                        }
                        continuation.yield(StateStreamUpdate(frame: frame, diagnostics: diagnostics))
                    } catch is CancellationError {
                        break
                    } catch {
                        diagnostics.decodeFailures += 1
                        diagnostics.lastFailureDescription = String(describing: error)
                        continuation.yield(StateStreamUpdate(frame: nil, diagnostics: diagnostics))
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
