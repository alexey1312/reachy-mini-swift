import Foundation
@testable import ReachyKit
import Testing

/// The queue's rules, which lived inside `ConnectionScreen` and were reachable only
/// through a snapshot until the sweep became a type of its own.
///
/// Nothing here lets the sweep dial anything: every case runs against a session that
/// is not `.idle`, or one whose automatic connection is paused, so `enqueue` fills the
/// queue and `startAutoConnectIfNeeded` declines to drain it. That is the seam — the
/// queueing rules are what this covers, and reaching the network is what it must not
/// do.
@MainActor
@Suite("CandidateSweep", .timeLimit(.minutes(1)))
struct CandidateSweepTests {
    private let a = RobotAddress(host: "10.0.0.1")
    private let b = RobotAddress(host: "10.0.0.2")

    /// Paused automatic connection is what keeps the drain from starting. The screen
    /// surfaces this state as "Automatic reconnect paused"; here it is the harness.
    private func makeSweep() -> CandidateSweep {
        let session = RobotSession.preview(phase: .idle, status: nil, address: nil, automaticConnectionAllowed: false)
        return CandidateSweep(session: session)
    }

    @Test("an address is queued once however many times it is offered")
    func queueDoesNotDuplicate() {
        let sweep = makeSweep()

        sweep.enqueue([a, b])
        sweep.enqueue([a])
        sweep.enqueue([b, a])

        #expect(sweep.pending == [a, b])
    }

    @Test("order is preserved, so the last known address stays ahead of the guesses")
    func queueKeepsOrder() {
        let sweep = makeSweep()
        let c = RobotAddress(host: "10.0.0.3")

        sweep.enqueue([b])
        sweep.enqueue([a, c])

        #expect(sweep.pending == [b, a, c])
    }

    @Test("a robot announced over Bluetooth is retried even after it failed once")
    func expectForgivesAnEarlierFailure() {
        let sweep = makeSweep()
        sweep.enqueue([a])

        // Stand in for the sweep having tried and failed against this address: the
        // provisioning flow is the one caller allowed to overrule that verdict,
        // because the robot has just told us where it landed.
        sweep.markAttemptedForTesting(a)
        sweep.enqueue([a])
        #expect(sweep.pending.contains(a) == false)

        sweep.expect(a)

        #expect(sweep.pending == [a])
        #expect(sweep.attempted.contains(a) == false)
    }

    @Test("an address already tried is not offered again")
    func attemptedAddressesAreNotRequeued() {
        let sweep = makeSweep()

        sweep.markAttemptedForTesting(a)
        sweep.enqueue([a, b])

        #expect(sweep.pending == [b])
    }
}
