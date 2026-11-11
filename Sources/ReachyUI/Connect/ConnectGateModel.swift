import Foundation
import Observation
import ReachyDesign
import ReachyKit
import ReachySimulator

/// What the connect gate shows that is its own, and what a reader can do on it.
///
/// `ConnectionScreen` held all of this in `@State`, with the actions as private
/// methods of the view. It is a model so that something other than the view can
/// read the gate and act on it: a test, and the introspection tree
/// (`docs/adr/0007-introspection-tree.md`).
///
/// The screen owns the model, and that is what keeps its lifetime: a gate that
/// comes back after a disconnect reads the last address again and shows the
/// Developer disclosure closed, as it did when these were `@State`.
@MainActor
@Observable
final class ConnectGateModel {
    let session: RobotSession
    let browser: RobotBrowser
    var manualInput: String
    var route: ConnectRoute
    var showsOnboarding = false
    /// Whether the Developer disclosure is open. Closed on every launch.
    var showsDeveloper: Bool
    /// The id of the Bonjour service that is being resolved, for its row's spinner.
    private(set) var resolving: String?
    private(set) var awaitedHardwareID: String?
    /// Built in `start()` unless injected: a preview injects them, and never starts.
    private(set) var knownRobots: KnownRobotsModel?
    private(set) var sweep: CandidateSweep?
    private(set) var localDaemon: LocalDaemonModel?
    /// Only a packaging failure can set this, and it is not `session.robotError`:
    /// nothing was asked of a robot, so nothing about the robot went wrong.
    private(set) var simulatorError: String?

    private let makeSimulator: @MainActor () -> (any RobotAPIClient)?
    private let resolve: @MainActor (RobotBrowser.DiscoveredService) async -> RobotAddress?

    init(
        session: RobotSession,
        browser: RobotBrowser,
        manualInput: String,
        awaitedHardwareID: String? = nil,
        knownRobots: KnownRobotsModel? = nil,
        sweep: CandidateSweep? = nil,
        localDaemon: LocalDaemonModel? = nil,
        route: ConnectRoute = .local,
        showsDeveloper: Bool = false,
        makeSimulator: @escaping @MainActor () -> (any RobotAPIClient)? = { SimulatedRobotClient() },
        resolve: @escaping @MainActor (RobotBrowser.DiscoveredService) async -> RobotAddress? = {
            await BonjourResolver.resolve($0.endpoint)
        }
    ) {
        self.session = session
        self.browser = browser
        self.manualInput = manualInput
        self.awaitedHardwareID = awaitedHardwareID
        self.knownRobots = knownRobots
        self.sweep = sweep
        self.localDaemon = localDaemon
        self.route = route
        self.showsDeveloper = showsDeveloper
        self.makeSimulator = makeSimulator
        self.resolve = resolve
    }

    /// Starts discovery, the sweep and the probes. The screen calls this when it
    /// appears, and never in preview mode.
    func start(offersLocalDaemon: Bool) {
        let robots = knownRobots ?? KnownRobotsModel()
        knownRobots = robots
        robots.start()
        browser.start()
        let sweep = sweep ?? CandidateSweep(session: session)
        self.sweep = sweep
        sweep.start()
        if offersLocalDaemon {
            let localDaemon = localDaemon ?? LocalDaemonModel()
            self.localDaemon = localDaemon
            localDaemon.start()
        }
        // Only the very first launch, and never as a gate: a robot already on the
        // network is found without any of this, and the button below reopens it.
        if KnownRobots.lastAddress == nil, !KnownRobots.hasCompletedOnboarding {
            showsOnboarding = true
        }
    }

    func stop() {
        sweep?.stop()
        browser.stop()
        knownRobots?.stop()
        localDaemon?.stop()
    }

    /// Bonjour found or lost a robot.
    func servicesChanged(_ services: [RobotBrowser.DiscoveredService]) {
        knownRobots?.updateDiscovered(Set(services.compactMap(\.hardwareID)))
        sweep?.resolve(services)
    }

    /// The robot reported where it landed over Bluetooth, which beats waiting for the
    /// sweep to stumble across it. The hardware id is what confirms the arrival, and
    /// `RobotSession` clears it on the handshake.
    func finishOnboarding(_ outcome: OnboardingOutcome) {
        showsOnboarding = false
        awaitedHardwareID = outcome.hardwareID
        guard let address = outcome.address else { return }
        sweep?.expect(address)
    }

    func connectManually(to address: RobotAddress) {
        sweep?.standDown()
        Task { await session.connect(to: address) }
    }

    /// Nothing to sweep for and nothing to resolve — the robot is built here.
    ///
    /// A simulator that cannot be built means the bundled description did not
    /// parse, which `BundledRobotGeometryTests` rules out at build time. Reported
    /// rather than crashed, because a resource is a packaging fact and the reader
    /// can still reach every other route on this screen.
    func connectToSimulator() {
        sweep?.standDown()
        guard let client = makeSimulator() else {
            simulatorError = String(localized: .reachy("The simulator's robot description could not be read."))
            return
        }
        simulatorError = nil
        Task { await session.connect(simulating: client) }
    }

    func connect(to service: RobotBrowser.DiscoveredService) {
        sweep?.standDown()
        resolving = service.id
        Task {
            defer { resolving = nil }
            guard let address = await resolve(service) else { return }
            await session.connect(to: address)
        }
    }
}
