import Foundation
@testable import ReachyKit
import Testing

/// The queue's rules, which lived inside `ConnectionScreen` and were reachable only
/// through a snapshot until the sweep became a type of its own.
///
/// The queueing cases run against a session whose automatic connection is paused, so
/// `enqueue` fills the queue and `startAutoConnectIfNeeded` declines to drain it. The
/// drain cases at the end hand the session stub clients, so a drain dials nothing
/// either: reaching the network is what no case here may do.
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

    // MARK: - The drain

    /// Measured by a third party on one LAN: another unit held the fallback name, and
    /// both reported `reachy_mini`. The remembered robot has a new lease, and its Bonjour
    /// result resolves after the static candidates. Every client is a stub, so nothing
    /// is dialled.
    @Test("the drain passes over another robot on the fallback name and takes the remembered one")
    func drainTakesTheRememberedRobot() async throws {
        let defaults = try #require(UserDefaults(suiteName: "CandidateSweepTests.\(UUID().uuidString)"))
        let store = KnownRobotStore(defaults: defaults)
        store.lastAddress = RobotAddress(host: "192.168.1.50")
        store.lastHardwareID = "hw-mine"
        let fallback = RobotAddress(host: "reachy-mini.local")
        let newLease = RobotAddress(host: "192.168.1.60")
        let stranger = AnsweringRobot(hardwareID: "hw-other")
        let mine = AnsweringRobot(hardwareID: "hw-mine")
        let session = RobotSession { address throws -> any RobotAPIClient in
            switch address {
            case fallback: stranger
            case newLease: mine
            default: throw URLError(.cannotConnectToHost)
            }
        }
        session.knownRobots = store
        let sweep = CandidateSweep(session: session, rescanInterval: .seconds(60))

        sweep.start()
        sweep.enqueue([newLease])
        await waitUntil {
            if case .connected = session.phase {
                true
            } else {
                false
            }
        }

        #expect(session.phase == .connected(mine.identity))
        #expect(sweep.attempted.contains(fallback))
        #expect(store.all.map(\.key) == ["hw-mine"])
        sweep.stop()
        session.disconnect()
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
