import Foundation
import Network
@testable import ReachyKit
import Testing

/// The queue's rules, which lived inside `ConnectionScreen` and were reachable only
/// through a snapshot until the sweep became a type of its own.
///
/// The queueing cases run against a session whose automatic connection is paused, so
/// `enqueue` fills the queue and `startAutoConnectIfNeeded` declines to drain it. The
/// drain cases at the end hand the session stub clients and the sweep a stub resolver,
/// so a drain dials nothing either: reaching the network is what no case here may do.
@MainActor
@Suite("CandidateSweep", .timeLimit(.minutes(1)))
struct CandidateSweepTests {
    private let a = RobotAddress(host: "10.0.0.1")
    private let b = RobotAddress(host: "10.0.0.2")
    private let oldLease = RobotAddress(host: "192.168.1.50")
    private let newLease = RobotAddress(host: "192.168.1.60")

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
        let store = try makeStore()
        store.lastAddress = oldLease
        store.lastHardwareID = "hw-mine"
        let fallback = RobotAddress(host: "reachy-mini.local")
        let stranger = AnsweringRobot(hardwareID: "hw-other")
        let mine = AnsweringRobot(hardwareID: "hw-mine")
        let session = RobotSession { [newLease] address throws -> any RobotAPIClient in
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

    // MARK: - Bonjour adverts

    /// The daemon's TXT `unit_id` names the robot before anything is dialled, so the sweep
    /// does not resolve a stranger's advert while the session holds to a robot. Nothing
    /// answers here: what is asserted is what the sweep asked for and what it dialled.
    @Test("an advert from another robot is neither resolved nor dialled while a robot is held")
    func passesOverAStrangersAdvert() async throws {
        let store = try makeStore()
        store.lastHardwareID = "hw-mine"
        store.pendingProvisionedHardwareID = "hw-new"
        let resolver = StubResolver([
            "stranger": RobotAddress(host: "10.0.0.9"),
            "legacy": RobotAddress(host: "10.0.0.7"),
            "provisioned": RobotAddress(host: "10.0.0.8"),
        ])
        let session = RobotSession { _ throws -> any RobotAPIClient in throw URLError(.cannotConnectToHost) }
        session.knownRobots = store
        let sweep = CandidateSweep(session: session, rescanInterval: .seconds(60)) { resolver.resolve($0) }
        let adverts = [
            advert("stranger", hardwareID: "hw-other"),
            // The legacy type carries no TXT record, so only a handshake can tell.
            advert("legacy", hardwareID: nil, type: "_http._tcp"),
            // Set up over Bluetooth a moment ago: the session takes it, so the sweep dials it.
            advert("provisioned", hardwareID: "hw-new"),
        ]

        sweep.start()
        sweep.resolve(adverts)
        await waitUntil {
            sweep.attempted.isSuperset(of: [RobotAddress(host: "10.0.0.7"), RobotAddress(host: "10.0.0.8")])
        }

        #expect(resolver.asked.sorted() == ["legacy", "provisioned"])
        #expect(sweep.attempted.contains(RobotAddress(host: "10.0.0.9")) == false)

        // A manual connect moved the hold. The advert passed over before is read again.
        store.lastHardwareID = "hw-other"
        sweep.resolve(adverts)
        await waitUntil { sweep.attempted.contains(RobotAddress(host: "10.0.0.9")) }

        #expect(resolver.asked.sorted() == ["legacy", "provisioned", "stranger"])
        sweep.stop()
    }

    /// Another unit holds `reachy-mini.local`, and the held robot advertises from a new
    /// lease. The advert puts that lease ahead of the fallback, so the stranger is never
    /// dialled. The old lease keeps the drain busy until the advert is in the queue.
    @Test("the held robot's advert goes ahead of the fallback name")
    func heldRobotsAdvertGoesFirst() async throws {
        let store = try makeStore()
        store.lastAddress = oldLease
        store.lastHardwareID = "hw-mine"
        let fallback = RobotAddress(host: "reachy-mini.local")
        let line = HeldLine()
        let mine = AnsweringRobot(hardwareID: "hw-mine")
        let stranger = AnsweringRobot(hardwareID: "hw-other")
        let session = RobotSession { [oldLease, newLease] address throws -> any RobotAPIClient in
            switch address {
            case oldLease: line
            case newLease: mine
            case fallback: stranger
            default: throw URLError(.cannotConnectToHost)
            }
        }
        session.knownRobots = store
        let resolver = StubResolver(["mine": newLease])
        let sweep = CandidateSweep(session: session, rescanInterval: .seconds(60)) { resolver.resolve($0) }
        defer {
            line.release()
            sweep.stop()
            session.disconnect()
        }

        sweep.start()
        await waitUntil { sweep.attempted.contains(oldLease) }
        sweep.resolve([advert("mine", hardwareID: "hw-mine")])
        await waitUntil { sweep.pending.contains(newLease) }

        #expect(sweep.pending.first == newLease)
        #expect(sweep.pending.contains(fallback))

        line.release()
        await waitUntil { session.phase == .connected(mine.identity) }

        #expect(session.phase == .connected(mine.identity))
        #expect(sweep.attempted.contains(fallback) == false)
    }

    /// A suite of its own: other suites connect against the shared store at the same time.
    private func makeStore() throws -> KnownRobotStore {
        let defaults = try #require(UserDefaults(suiteName: "CandidateSweepTests.\(UUID().uuidString)"))
        return KnownRobotStore(defaults: defaults)
    }

    private func advert(
        _ name: String,
        hardwareID: String?,
        type: String = "_reachy-mini._tcp"
    ) -> RobotBrowser.DiscoveredService {
        RobotBrowser.DiscoveredService(
            name: name,
            type: type,
            endpoint: .service(name: name, type: type, domain: "local.", interface: nil),
            hardwareID: hardwareID
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Answers in place of `BonjourResolver`, which opens a TCP connection to each advert,
/// and records which adverts the sweep asked it about.
@MainActor
private final class StubResolver {
    private let addresses: [String: RobotAddress]
    private(set) var asked: [String] = []

    init(_ addresses: [String: RobotAddress]) {
        self.addresses = addresses
    }

    func resolve(_ service: RobotBrowser.DiscoveredService) -> RobotAddress? {
        asked.append(service.name)
        return addresses[service.name]
    }
}

/// A daemon that keeps the drain on one candidate until the test releases it, and then
/// does not answer.
private final class HeldLine: RobotAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func release() {
        lock.withLock { released = true }
    }

    func handshake() async throws -> RobotConnection.Handshake {
        while !lock.withLock({ released }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cannotConnectToHost)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        throw URLError(.cannotConnectToHost)
    }

    func wakeUp() async throws -> String {
        throw URLError(.cannotConnectToHost)
    }

    func gotoSleep() async throws -> String {
        throw URLError(.cannotConnectToHost)
    }
}
