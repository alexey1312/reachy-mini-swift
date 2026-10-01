import Foundation
import ReachyKit
@preconcurrency import WebRTC

/// How long a negotiation may take, and what happens when it takes longer (#155).
///
/// An *attempt* is one subscription to signaling — on the LAN a socket and a
/// `startSession`, over the relay an event stream and an ask — and it has
/// `negotiationDeadline` to reach a connected peer. Whatever it stalls on is the same
/// stall: an offer that never comes, an answer the robot never receives, ICE that
/// never leaves `checking`. A stall starts the attempt over once, from the top — a new
/// subscription rather than the old one resumed — and a second stall in a row ends in
/// `.stalled`, with signaling dropped, until `retry()`. Connecting refills the budget,
/// so a stream that drops after working gets the same one retry.
///
/// **The robot does not tell the LAN when it gives up.** Daemon 1.10+ runs a 12 s
/// watchdog of its own (`ICE_NEGOTIATION_DEADLINE_S` in `media_server.py`) and reports
/// a stuck peer only to central — as `ice_negotiation_timeout` or
/// `peer_connection_failed` — while for a peer on its own socket it logs and does
/// nothing. So on the LAN this deadline is the only thing that ever ends a stalled
/// negotiation, and over the relay the robot's verdict counts as a stall exactly like
/// this deadline passing.
///
/// A file of its own because `CameraSession.swift` reached SwiftLint's length limit.
extension CameraSession {
    /// Covers the robot's own 12 s and the signaling ahead of it, so over the relay its
    /// typed verdict usually lands first. A healthy LAN negotiation takes under a second.
    static let defaultNegotiationDeadline: Duration = .seconds(15)
    /// The first try and one retry.
    static let attemptsBeforeStalling = 2

    /// Starts over after `.stalled`, with a fresh budget. Anything else is left alone: a
    /// `.failed` session was refused by something that a retry would only fight.
    public func retry() {
        guard isStarted, phase == .stalled else { return }
        stalledAttempts = 0
        phase = .connecting
        subscribe()
    }

    // MARK: - Attempts

    /// Asks the carrier for a session and starts that attempt's clock.
    func subscribe() {
        let ending = ending
        // `weak self`: `handle` captures the session, so a strong capture keeps
        // `self → eventsTask → self` alive for as long as the signaling stream
        // runs — an owner that drops the session without `stop()` would leak it
        // and its socket (`RobotSceneModel.startStreaming` makes the same trade).
        eventsTask = Task { [weak self, signaling, connection] in
            await ending?.value
            // Sim registers no producer until media is acquired; harmless elsewhere.
            try? await connection?.acquireMedia()
            for await event in await signaling.events() {
                // A replaced subscription can still hold an event; it is not this attempt's.
                guard let self, !Task.isCancelled else { return }
                await handle(event)
            }
        }
        armDeadline()
    }

    /// Drops the subscription and ends the robot's half of it. Best-effort
    /// `endSession`; on the LAN the socket closing would do as much.
    func unsubscribe() {
        eventsTask?.cancel()
        eventsTask = nil
        let previous = ending
        ending = Task { [signaling] in
            await previous?.value
            await signaling.disconnect()
        }
    }

    /// The first stall starts the attempt over; the second in a row reports it. Reached
    /// from the deadline, from a peer that failed, and from the robot's own watchdog.
    func negotiationStalled() {
        guard isStarted else { return }
        stalledAttempts += 1
        teardownPeer()
        unsubscribe()
        disarmDeadline()
        guard stalledAttempts < Self.attemptsBeforeStalling else {
            // An ending, not a lull: commands waiting on the control channel fail now
            // rather than wait for a session nothing is asking for any more.
            dataChannel.close()
            poseChannel.close()
            phase = .stalled
            return
        }
        phase = .connecting
        subscribe()
    }

    /// The peer connection's own verdict, from the delegate adapter. `id` names the peer
    /// it came from, because a closed peer still reports — and a `failed` from the one a
    /// restart just replaced would otherwise count against its successor.
    func peer(_ id: ObjectIdentifier, changedTo state: RTCPeerConnectionState) {
        guard let peerConnection, ObjectIdentifier(peerConnection) == id else { return }
        switch state {
        case .connected:
            disarmDeadline()
            stalledAttempts = 0
            phase = .streaming
        case .failed:
            negotiationStalled()
        default:
            break
        }
    }

    // MARK: - The deadline

    func armDeadline() {
        deadlineTask?.cancel()
        let deadline = negotiationDeadline
        deadlineTask = Task { [weak self] in
            guard await (try? Task.sleep(for: deadline)) != nil else { return }
            self?.deadlinePassed()
        }
    }

    /// For a step inside an attempt that may or may not have a clock running: an offer
    /// after the robot said it had no producer starts one, an offer within an attempt
    /// keeps the one it has.
    func armDeadlineIfIdle() {
        guard deadlineTask == nil else { return }
        armDeadline()
    }

    func disarmDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func deadlinePassed() {
        deadlineTask = nil
        guard phase == .connecting else { return }
        negotiationStalled()
    }
}
