import Foundation
import Observation
import ReachyKit

/// What the connection rail is showing, which is not always what the session is
/// doing.
///
/// On a local network all three stages resolve in tens of milliseconds, so a rail
/// drawn straight off `RobotSession.phase` is a flash with no readable shape. This
/// holds each stage on screen for a floor of `dwell` before letting the next one
/// through — a lower bound only: a stage that genuinely takes ten seconds is not
/// touched, and nothing here invents progress the session has not made.
///
/// It also decides when the gate may hand over. `ReachyRootView` swaps the gate
/// for the tab shell the instant the phase turns `.connected` and throws the whole
/// subtree away; without `holdsGate` the rail would vanish before drawing a single
/// checkmark and the dwell would buy nothing at all.
@MainActor
@Observable
final class ConnectProgressModel {
    private(set) var displayed: RobotSession.ConnectionPhase = .idle

    /// The gate must stay up. True while stages are still queued, and — the part
    /// that is easy to get wrong — for one further `dwell` after the last of them
    /// is shown. Without that final wait the happy path draws its three checkmarks
    /// into a frame the root replaces in the same tick, which is the whole reason
    /// any of this exists.
    private(set) var holdsGate = false

    private let dwell: Duration
    /// The ceiling on holding the gate, measured from the first phase the queue had
    /// to defer.
    ///
    /// The design argued no watchdog was needed, on the grounds that a newest-wins
    /// rule cannot hold longer than one dwell. Queueing is what changed that: it is
    /// what makes the middle stage visible at all, and it also makes the hold
    /// `queue × dwell`. Bounded in principle — but a bound that depends on how many
    /// phases happened to arrive is not one to put between the user and their app.
    /// This one depends on nothing.
    private let maxHold: Duration
    private let clock: ContinuousClock

    private var queue: [RobotSession.ConnectionPhase] = []
    private var shownAt: ContinuousClock.Instant?
    private var holdingSince: ContinuousClock.Instant?
    private var drain: Task<Void, Never>?

    /// `dwell: .zero` takes every call down the immediate path, so no task is ever
    /// started and `displayed` tracks `observe` synchronously. That is what previews
    /// and snapshots use, and it is why injecting it makes the root behave in a
    /// reference image exactly as it did before this type existed.
    init(
        initialPhase: RobotSession.ConnectionPhase = .idle,
        dwell: Duration = .milliseconds(300),
        maxHold: Duration = .milliseconds(1500),
        clock: ContinuousClock = ContinuousClock()
    ) {
        displayed = initialPhase
        self.dwell = dwell
        self.maxHold = maxHold
        self.clock = clock
    }

    /// The session moved. Safe to call with a phase that is already showing.
    func observe(_ phase: RobotSession.ConnectionPhase) {
        guard phase != queue.last else { return }
        guard phase != displayed || !queue.isEmpty else { return }

        if dwell == .zero || showsWithoutWaiting(phase) {
            cancelDrain()
            queue = []
            show(phase)
            return
        }

        // Nothing is being displaced — either this is the first frame of an attempt,
        // or the frame on screen has already had more than its floor because the
        // stage genuinely took that long. Queueing here would defer the one phase
        // that has nothing to wait for by a main-actor hop, and hand the gate a
        // `holdsGate` it has no reason to hold.
        if queue.isEmpty, remainingDwell() == nil, !holdsAfterShowing(phase) {
            show(phase)
            return
        }

        queue.append(phase)
        startDrainIfNeeded()
    }

    /// Nothing queued survives the attempt being abandoned.
    func reset() {
        cancelDrain()
        queue = []
        show(.idle)
    }

    /// Bad news is never held, and neither is an attempt that stopped. A failure, an
    /// unsupported daemon and a stopped backend each need the user now, and each is
    /// terminal — there is no later stage whose turn would be taken by showing it.
    /// `.idle` is the same story from the other end: the attempt was cancelled, and
    /// animating towards a state nobody is heading for would be a lie.
    private func showsWithoutWaiting(_ phase: RobotSession.ConnectionPhase) -> Bool {
        switch phase {
        case .idle: true
        case .connected, .unreachable: false
        case let .connecting(step):
            switch step {
            case .failed, .backendUnavailable, .needsDaemonUpdate: true
            case .handshaking, .checkingBackend: false
            }
        }
    }

    /// A successful connection gets one complete frame of its own even when the
    /// previous stage had already satisfied its dwell. Without this distinction a
    /// slow handshake takes the immediate path above, draws the checkmarks and lets
    /// the root replace the gate in the same update.
    private func holdsAfterShowing(_ phase: RobotSession.ConnectionPhase) -> Bool {
        switch phase {
        case .connected, .unreachable: true
        case .idle, .connecting: false
        }
    }

    private func startDrainIfNeeded() {
        guard drain == nil else { return }
        holdsGate = true
        if holdingSince == nil {
            holdingSince = clock.now
        }
        drain = Task { @MainActor [weak self] in await self?.drainQueue() }
    }

    private func drainQueue() async {
        repeat {
            while !queue.isEmpty {
                await waitOutDwell()
                guard !Task.isCancelled else { return }
                show(queue.removeFirst())
            }
            await waitOutDwell()
            guard !Task.isCancelled else { return }
            // A phase observed during that trailing dwell was queued — `observe`
            // saw the frame still inside its floor, and `startDrainIfNeeded`
            // no-oped because this task still existed. Releasing the gate over
            // it would strand it forever: `observe` only runs on a phase
            // *change*, so a session already settled on `.connected` never
            // fires again, and the gate sits on the previous stage for good.
        } while !queue.isEmpty
        holdsGate = false
        drain = nil
        holdingSince = nil
    }

    private func waitOutDwell() async {
        guard let remaining = remainingDwell() else { return }
        try? await clock.sleep(for: remaining)
    }

    /// How much longer the current frame has to stay, or `nil` if it may go now —
    /// either it has had its turn, or the ceiling ran out and everything left is
    /// flushed without waiting.
    private func remainingDwell() -> Duration? {
        guard let shownAt else { return nil }
        let now = clock.now
        let elapsed = now - shownAt
        guard elapsed < dwell else { return nil }
        let remaining = dwell - elapsed
        guard let holdingSince else { return remaining }
        let held = now - holdingSince
        guard held < maxHold else { return nil }
        return min(remaining, maxHold - held)
    }

    private func show(_ phase: RobotSession.ConnectionPhase) {
        displayed = phase
        shownAt = clock.now
    }

    /// Releasing the gate here is not tidying up: a failure arriving mid-drain takes
    /// this path, and leaving `holdsGate` set would strand the user in a gate whose
    /// rail has already stopped moving.
    private func cancelDrain() {
        drain?.cancel()
        drain = nil
        holdingSince = nil
        holdsGate = false
    }
}

#if DEBUG
    extension ConnectProgressModel {
        /// A model parked on one phase, for previews and snapshots. Zero dwell, so it
        /// starts no task and never holds the gate.
        static func preview(_ phase: RobotSession.ConnectionPhase = .idle) -> ConnectProgressModel {
            ConnectProgressModel(initialPhase: phase, dwell: .zero)
        }
    }
#endif
