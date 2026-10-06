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
/// `.stalled`, with signaling dropped, until `retry()` — or, on the LAN, until a probe
/// gets through. Connecting refills the budget, so a stream that drops after working
/// gets the same one retry.
///
/// **The robot does not tell the LAN when it gives up.** Daemon 1.10+ runs a 12 s
/// watchdog of its own (`ICE_NEGOTIATION_DEADLINE_S` in `media_server.py`) and reports
/// a stuck peer only to central — as `ice_negotiation_timeout` or
/// `peer_connection_failed` — while for a peer on its own socket it logs and does
/// nothing. So on the LAN this deadline is the only thing that ever ends a stalled
/// negotiation, and over the relay the robot's verdict counts as a stall exactly like
/// this deadline passing.
///
/// **Nor does it tell the LAN when it is back.** A robot that goes away for longer than
/// both attempts and comes back with its backend still up — a Wi-Fi outage, which the
/// status poll sits out on its last reading; a media server slow to return — gives the
/// viewport nothing to rebuild the session on. Before this deadline the session simply
/// reconnected for ever; so on the LAN `.stalled` is probed, slowly (`scheduleProbe()`).
///
/// A file of its own because `CameraSession.swift` reached SwiftLint's length limit.
extension CameraSession {
    /// Covers the robot's own 12 s and the signaling ahead of it, so over the relay its
    /// typed verdict usually lands first. A healthy LAN negotiation takes under a second.
    static let defaultNegotiationDeadline: Duration = .seconds(15)
    /// The first try and one retry.
    static let attemptsBeforeStalling = 2
    /// The first wait on the LAN between `.stalled` and a probe.
    static let defaultProbeDelay: Duration = .seconds(15)
    /// How often a probe that stalls too doubles the wait before the next: 15 s, 30 s,
    /// then a minute from there on, for as long as the robot stays away.
    static let probeDoublings = 2

    /// Starts over after `.stalled`, with a fresh budget. Anything else is left alone: a
    /// `.failed` session was refused by something that a retry would only fight.
    public func retry() {
        guard isStarted, phase == .stalled else { return }
        // A probe may be listening, and a carrier serves one subscription at a time.
        if eventsTask != nil {
            unsubscribe()
        }
        stalledAttempts = 0
        phase = .connecting
        subscribe()
    }

    // MARK: - Attempts

    /// Asks the carrier for a session and starts that attempt's clock.
    ///
    /// A probe does not acquire media. The simulator registers no producer until it
    /// is asked to, but on a robot whose camera an app released for direct access the
    /// same request takes the camera back — and a probe is something nobody asked for.
    func subscribe(acquiringMedia: Bool = true) {
        let ending = ending
        let acquirer = acquiringMedia ? connection : nil
        // `weak self`: `handle` captures the session, so a strong capture keeps
        // `self → eventsTask → self` alive for as long as the signaling stream
        // runs — an owner that drops the session without `stop()` would leak it
        // and its socket (`RobotSceneModel.startStreaming` makes the same trade).
        eventsTask = Task { [weak self, signaling, acquirer] in
            await ending?.value
            try? await acquirer?.acquireMedia()
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
            // rather than wait for a session that at most a slow probe still asks for.
            dataChannel.close()
            poseChannel.close()
            phase = .stalled
            scheduleProbe()
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

    /// The carrier asked a producer for a session, so an offer is owed. After a wait
    /// that is the robot back — registered late, just woken, its media server
    /// restarted — and the clock the wait stopped starts again here: a producer that
    /// appears and then never offers is a stall like any other, not a wait for ever.
    func sessionRequested() {
        guard phase == .waitingForProducer else { return }
        phase = .connecting
        armDeadlineIfIdle()
    }

    /// For a step inside an attempt that may or may not have a clock running: a session
    /// asked for, or an offer, after the robot said it had no producer starts one; the
    /// same step within an attempt keeps the one it has.
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
        // `.stalled` here is a probe the robot never answered.
        guard phase == .connecting || phase == .stalled else { return }
        negotiationStalled()
    }

    // MARK: - Probes

    /// Waits, and then tries once more. The wait holds the deadline's slot, which a
    /// `.stalled` session has no attempt to fill — so whatever disarms a deadline also
    /// cancels a probe still waiting: `stop()`, and `retry()` arming its own.
    func scheduleProbe() {
        guard let probeDelay else { return }
        let wait = Self.probeWait(first: probeDelay, stalledProbes: stalledAttempts - Self.attemptsBeforeStalling)
        deadlineTask = Task { [weak self] in
            guard await (try? Task.sleep(for: wait)) != nil else { return }
            self?.probe()
        }
    }

    /// One attempt on the usual deadline, with the phase left at `.stalled` until the
    /// robot answers — a robot still away changes nothing on screen, and the Try again
    /// button stays. The budget is already spent, so a probe that stalls is `.stalled`
    /// again at once and the next one waits longer.
    private func probe() {
        deadlineTask = nil
        guard isStarted, phase == .stalled else { return }
        subscribe(acquiringMedia: false)
    }

    /// The wait before the next probe, once this many probes have stalled too.
    static func probeWait(first: Duration, stalledProbes: Int) -> Duration {
        first * (1 << min(max(stalledProbes, 0), probeDoublings))
    }
}
