import Foundation
import ReachyKit
@preconcurrency import WebRTC

/// `ReachyKit`'s `RemoteDataChannel`, carried by the real thing.
///
/// The robot opens exactly one channel, labelled `"data"`
/// (`media_server.py`, `create-data-channel`), and it opens it *after*
/// negotiation — so this exists before there is anything behind it, and a send
/// issued too early waits rather than fails. `RemoteControlChannel` imposes the
/// deadline that bounds that wait.
///
/// Untested by design, like `CameraSession`: `RTCDataChannel` cannot be stood up
/// outside a live peer connection. The seam that *is* tested is
/// `RemoteDataChannel` itself, against a scripted double.
public final class WebRTCDataChannel: NSObject, RemoteDataChannel, @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The channel took the buffer and refused it — full, or closing.
        case refused
        /// The session ended while a send was still waiting for a channel.
        /// Appended after `refused`: a bare enum reaches the UI as its
        /// declaration index.
        case closed
    }

    /// Messages that arrive before anyone is listening. Capped because the robot
    /// broadcasts joint positions at 50 Hz: an uncapped backlog would grow for as
    /// long as nothing reads it, and the oldest frame is the one worth dropping.
    private static let backlogLimit = 64

    private let lock = NSLock()
    private var channel: RTCDataChannel?
    private var continuation: AsyncStream<String>.Continuation?
    private var backlog: [String] = []
    private var waitingForChannel: [CheckedContinuation<RTCDataChannel, any Error>] = []

    public func messages() -> AsyncStream<String> {
        AsyncStream { continuation in
            lock.lock()
            let previous = self.continuation
            self.continuation = continuation
            let pending = backlog
            backlog = []
            lock.unlock()
            // A replaced subscriber must hear the end of its stream, not hang on
            // a continuation nothing will ever yield to again.
            previous?.finish()
            for text in pending {
                continuation.yield(text)
            }
        }
    }

    /// Exactly while a peer connection has handed its channel over: not before the
    /// first negotiation finishes, and not between peers while a session heals.
    /// `send` waits in both of those, which is what makes this the honest answer.
    public var isOpen: Bool {
        current() != nil
    }

    public func send(_ text: String) async throws {
        let channel = try await attachedChannel()
        let buffer = RTCDataBuffer(data: Data(text.utf8), isBinary: false)
        guard channel.sendData(buffer) else { throw Failure.refused }
    }

    /// Teleop frames are useful only to the peer that exists now. Taking a local
    /// snapshot of the attached channel avoids entering `attachedChannel()` and
    /// therefore cannot leave a stale frame suspended across renegotiation.
    public func sendIfOpen(_ text: String) async throws -> Bool {
        guard let channel = current() else { return false }
        let buffer = RTCDataBuffer(data: Data(text.utf8), isBinary: false)
        guard channel.sendData(buffer) else { throw Failure.refused }
        return true
    }

    /// Called once the robot's channel is open. Anything already waiting to send
    /// goes out now. The channel being replaced, if any, stops calling back —
    /// its delegate is cleared so a late `.closed` from it cannot reach us.
    func attach(_ channel: RTCDataChannel) {
        channel.delegate = self
        lock.lock()
        let replaced = self.channel
        self.channel = channel
        let waiting = waitingForChannel
        waitingForChannel = []
        lock.unlock()
        if let replaced, replaced !== channel {
            replaced.delegate = nil
        }
        for continuation in waiting {
            continuation.resume(returning: channel)
        }
    }

    /// The peer connection was replaced. Every re-negotiation does this — including
    /// the very first offer, which arrives after this object already exists — so it
    /// is a gap, not an ending: sends go back to waiting for a channel and the
    /// message stream is deliberately left running. Ending it here would tell
    /// `RemoteControlChannel` the session was over and fail the handshake that is
    /// waiting for this negotiation to finish.
    func detachPeer() {
        lock.lock()
        let dropped = channel
        channel = nil
        lock.unlock()
        dropped?.delegate = nil
    }

    /// The session is gone. Ends the message stream, which is what tells
    /// `RemoteControlChannel` to fail everything still pending — and fails the
    /// sends still waiting for a channel, which otherwise stay suspended (and
    /// retained, with their payloads) forever.
    func close() {
        lock.lock()
        let dropped = channel
        channel = nil
        let continuation = continuation
        self.continuation = nil
        backlog = []
        let waiting = waitingForChannel
        waitingForChannel = []
        lock.unlock()
        dropped?.delegate = nil
        for waiter in waiting {
            waiter.resume(throwing: Failure.closed)
        }
        continuation?.finish()
    }

    private func attachedChannel() async throws -> RTCDataChannel {
        if let channel = current() {
            return channel
        }
        return try await withCheckedThrowingContinuation { continuation in
            enqueue(continuation)
        }
    }

    /// Synchronous on purpose: `NSLock` is `noasync`, and a lock held across a
    /// suspension is a deadlock waiting for the right scheduling.
    private func current() -> RTCDataChannel? {
        lock.lock()
        defer { lock.unlock() }
        return channel
    }

    private func enqueue(_ continuation: CheckedContinuation<RTCDataChannel, any Error>) {
        lock.lock()
        // Attached between the check and here — resume rather than wait forever.
        if let channel {
            lock.unlock()
            continuation.resume(returning: channel)
            return
        }
        waitingForChannel.append(continuation)
        lock.unlock()
    }

    private func deliver(_ text: String) {
        lock.lock()
        let listener = continuation
        if listener == nil {
            backlog.append(text)
            if backlog.count > Self.backlogLimit {
                backlog.removeFirst(backlog.count - Self.backlogLimit)
            }
        }
        lock.unlock()
        listener?.yield(text)
    }
}

extension WebRTCDataChannel: RTCDataChannelDelegate {
    /// One channel closing is one peer going away, which the session heals by
    /// negotiating another — so the control channel above is left intact.
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .closed else { return }
        // Only the channel currently attached may detach the peer. The *old*
        // channel's asynchronous `.closed` lands here after a renegotiation has
        // already attached its replacement, and detaching unconditionally nils
        // the new channel out — sends wait forever while messages still arrive,
        // a half-dead control surface with no visible cause.
        guard dataChannel === current() else { return }
        detachPeer()
    }

    /// The daemon speaks JSON text on this channel; a binary frame is not ours.
    public func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let text = String(bytes: buffer.data, encoding: .utf8) else { return }
        deliver(text)
    }
}
