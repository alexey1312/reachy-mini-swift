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
///
/// **One reader, many subscribers.** `WebRTCDataChannel.messages()` hands its
/// stream to a single consumer and finishes the previous one, so the 3D scene and
/// the hearing indicator cannot each open their own — the second would silently
/// take the first's frames. This reads the channel once and fans the result out,
/// which is also what keeps `subscribe_pose` to one send.
public final class RemotePoseStream: RobotStateStreaming, @unchecked Sendable {
    private let connection: RemoteRobotConnection
    private let channel: any RemoteDataChannel
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<StateStreamUpdate>.Continuation] = [:]
    private var reader: Task<Void, Never>?

    /// How many unreadable frames in a row before the channel is written off.
    ///
    /// Generous: the robot publishes at about 30 Hz, so this is a second of a
    /// channel saying nothing intelligible — long enough that one malformed frame,
    /// or one from a version this build predates, cannot trigger it.
    private static let patience = 30

    public init(connection: RemoteRobotConnection, channel: any RemoteDataChannel) {
        self.connection = connection
        self.channel = channel
    }

    deinit { reader?.cancel() }

    /// The options are read for nothing here, and that is the daemon's choice:
    /// the publisher runs at its own rate and takes no arguments. A viewer asking
    /// for 20 Hz gets 30 and is none the worse for it.
    public func updates(_: StateStreamOptions) -> AsyncStream<StateStreamUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                subscribers[id] = continuation
                startReadingLocked()
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    private func remove(_ id: UUID) {
        let idle: Bool = lock.withLock {
            subscribers.removeValue(forKey: id)
            return subscribers.isEmpty
        }
        // The last one out asks the robot to stop publishing. Nothing depends on
        // it landing — a robot still pushing to a channel nobody reads costs the
        // link, not correctness.
        guard idle else { return }
        let stopped = lock.withLock { () -> Task<Void, Never>? in
            defer { reader = nil }
            return reader
        }
        stopped?.cancel()
    }

    /// Called under `lock`.
    private func startReadingLocked() {
        guard reader == nil else { return }
        reader = Task { [connection, channel] in
            // Subscribed before the stream is read, not after: the daemon starts
            // publishing the moment it is asked, and a reader set up afterwards
            // would drop the first frames on the floor.
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
                    // A channel that talks and says nothing this build can read is
                    // the one failure here that is invisible: the model would stop
                    // moving, which looks like a still robot rather than a bug.
                    // Give up on it and ask instead — polling is slower and works.
                    if diagnostics.decodedFrames == 0, diagnostics.decodeFailures >= Self.patience {
                        await self.pollInstead(diagnostics: diagnostics)
                        return
                    }
                    continue
                }
                guard frame.seq > newest else {
                    // Out of order, which this channel is allowed to be.
                    diagnostics.unsupportedFrames += 1
                    continue
                }
                newest = frame.seq
                diagnostics.decodedFrames += 1
                self.broadcast(StateStreamUpdate(
                    frame: frame.state.frame,
                    diagnostics: diagnostics
                ))
            }
            self.finishAll()
        }
    }

    /// Hands every subscriber over to the polled stream and keeps them there: a
    /// channel that spoke unintelligibly is not going to start making sense.
    private func pollInstead(diagnostics: StateStreamDiagnostics) async {
        try? await connection.unsubscribeFromPose()
        var carried = diagnostics
        for await update in RemoteStateStream(connection: connection).updates(.visualization) {
            guard !Task.isCancelled else { break }
            carried.receivedFrames += 1
            carried.decodedFrames += update.frame == nil ? 0 : 1
            broadcast(StateStreamUpdate(frame: update.frame, diagnostics: carried))
        }
        finishAll()
    }

    private func broadcast(_ update: StateStreamUpdate) {
        for continuation in lock.withLock({ subscribers.values }) {
            continuation.yield(update)
        }
    }

    private func finishAll() {
        for continuation in lock.withLock({ subscribers.values }) {
            continuation.finish()
        }
    }
}
