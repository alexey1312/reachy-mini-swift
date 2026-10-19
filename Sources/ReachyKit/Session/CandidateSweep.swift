import Foundation
import Observation

/// The background hunt for a robot to talk to: which addresses are worth trying,
/// which have been tried, and the retry that keeps a robot powered on later from
/// going unnoticed.
///
/// Lifted out of `ConnectionScreen`, which asked for exactly this in a comment
/// before anything else was added to it. Two things come with the move: the screen
/// drops back under SwiftLint's body ceiling, and the queue's rules — never try one
/// address twice, never sweep while the user is driving — become testable without a
/// snapshot.
///
/// Identity, not address, decides what counts as the same robot everywhere else
/// (project rule 4). Here it is genuinely addresses: a sweep's whole job is to find
/// out which of several addresses answers. Which robot it may then take is the
/// session's decision (`RobotSession.admitsAutomatically`): an answer from another
/// robot is an address that failed, and the drain goes on to the next one.
/// A Bonjour advert names its robot before anything is dialled, so the sweep reads
/// that first: see `resolve(_:)`.
///
/// It lives in ReachyKit rather than beside the screen because two shells run it:
/// the phone's connect gate and the TV app's, which links no ReachyUI.
@MainActor
@Observable
public final class CandidateSweep {
    private let session: RobotSession
    /// Upstream's `INTERVALS.DISCOVERY_SCAN`.
    private let rescanInterval: Duration

    public private(set) var pending: [RobotAddress] = []
    public private(set) var attempted: Set<RobotAddress> = []
    private var resolvedServiceIDs: Set<String> = []
    private var autoConnect: Task<Void, Never>?
    private var rescan: Task<Void, Never>?
    /// A real resolve opens a TCP connection to the advert, so a test replaces it.
    private let resolveService: @MainActor (RobotBrowser.DiscoveredService) async -> RobotAddress?

    public init(
        session: RobotSession,
        rescanInterval: Duration = .seconds(10),
        resolveService: @escaping @MainActor (RobotBrowser.DiscoveredService) async -> RobotAddress? = {
            await BonjourResolver.resolve($0.endpoint)
        }
    ) {
        self.session = session
        self.rescanInterval = rescanInterval
        self.resolveService = resolveService
    }

    public func start() {
        enqueueInitialCandidates()
        startPeriodicRescan()
    }

    public func stop() {
        autoConnect?.cancel()
        autoConnect = nil
        rescan?.cancel()
        rescan = nil
    }

    /// The user took over. The sweep must not race a hand-picked address, and its
    /// queue must not resume behind one.
    public func standDown() {
        autoConnect?.cancel()
        autoConnect = nil
    }

    /// The robot reported over Bluetooth where it landed, which beats waiting for
    /// the sweep to stumble across it. A previous failure against that address is
    /// forgiven — it was a different robot's turn then.
    public func expect(_ address: RobotAddress) {
        attempted.remove(address)
        enqueue([address])
    }

    public func enqueue(_ candidates: [RobotAddress]) {
        for candidate in candidates where !attempted.contains(candidate) && !pending.contains(candidate) {
            pending.append(candidate)
        }
        startAutoConnectIfNeeded()
    }

    /// Queues each advert's address, read off its TXT `unit_id` before anything is dialled.
    ///
    /// While the session holds to a robot, another robot's advert is not resolved at all:
    /// its handshake could only end in a pass-over. It is not marked resolved either, so
    /// the next call reads it again against the hold as it is then. The held robot's
    /// address, or that of a robot set up over Bluetooth a moment ago, goes ahead of the
    /// guesses still waiting. An advert without the record — the legacy `_http._tcp`
    /// type — is queued as before, and the handshake decides.
    /// The session stays the authority; this only saves a handshake with a stranger.
    public func resolve(_ services: [RobotBrowser.DiscoveredService]) {
        guard session.automaticConnectionAllowed else { return }
        for service in services where !resolvedServiceIDs.contains(service.id) {
            let placement = placement(of: service)
            guard placement != .passOver else { continue }
            resolvedServiceIDs.insert(service.id)
            Task { @MainActor in
                guard let address = await resolveService(service) else { return }
                if placement == .ahead {
                    enqueueAhead(address)
                } else {
                    enqueue([address])
                }
            }
        }
    }

    private enum Placement {
        case ahead, behind, passOver
    }

    private func placement(of service: RobotBrowser.DiscoveredService) -> Placement {
        guard session.knownRobots.lastHardwareID != nil, let advertised = service.hardwareID else { return .behind }
        return session.admitsAutomatically(hardwareID: advertised) ? .ahead : .passOver
    }

    /// The advert proves that a robot the session takes is at `candidate`, which beats
    /// every guess still waiting, `reachy-mini.local` included. An address already
    /// dialled stays dialled, as in `enqueue`.
    private func enqueueAhead(_ candidate: RobotAddress) {
        guard !attempted.contains(candidate) else { return }
        pending.removeAll { $0 == candidate }
        pending.insert(candidate, at: 0)
        startAutoConnectIfNeeded()
    }

    /// Tries known and static candidates first; Bonjour results are appended as
    /// they resolve, except the held robot's, which `resolve(_:)` puts first.
    private func enqueueInitialCandidates() {
        guard session.automaticConnectionAllowed else { return }
        // Upstream also probes `reachy-mini.home`, which cannot work here: App
        // Transport Security exempts `.local`, link-local and single-label names
        // from its HTTPS requirement, and a qualified `.home` name is none of
        // those. Probing it only ever produced a -1022 error on screen.
        var candidates = [RobotAddress(host: "reachy-mini.local")]
        #if os(macOS) || targetEnvironment(simulator)
            // A simulated daemon runs on this Mac and advertises no Bonjour the
            // simulator can see; loopback reaches the host either way.
            candidates.insert(RobotAddress(host: "127.0.0.1"), at: 0)
        #endif
        if let last = session.knownRobots.lastAddress {
            candidates.insert(last, at: 0)
        }
        enqueue(candidates)
    }

    /// A robot powered on after this screen appeared advertises nothing the browser
    /// can react to when mDNS does not reach us, so known addresses are retried
    /// rather than written off after one failed pass.
    private func startPeriodicRescan() {
        rescan?.cancel()
        rescan = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: rescanInterval)
                guard !Task.isCancelled, session.phase == .idle else { continue }
                attempted = []
                enqueueInitialCandidates()
            }
        }
    }

    #if DEBUG
        /// Records an address as already tried without dialling it.
        ///
        /// For the queueing rules, whose tests keep the drain from starting. The drain
        /// itself is tested through a session whose `makeClient` hands out stubs.
        func markAttemptedForTesting(_ address: RobotAddress) {
            attempted.insert(address)
            pending.removeAll { $0 == address }
        }
    #endif

    private func startAutoConnectIfNeeded() {
        guard autoConnect == nil,
              session.automaticConnectionAllowed,
              session.phase == .idle,
              !pending.isEmpty
        else { return }

        autoConnect = Task { @MainActor [weak self] in
            defer { self?.autoConnect = nil }
            while let self,
                  !Task.isCancelled,
                  session.automaticConnectionAllowed,
                  session.phase == .idle,
                  !pending.isEmpty
            {
                let candidate = pending.removeFirst()
                attempted.insert(candidate)
                if await session.connect(to: candidate, automatically: true) {
                    return
                }
            }
        }
    }
}
