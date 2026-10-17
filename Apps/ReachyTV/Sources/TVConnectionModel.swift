import Foundation
import Observation
import ReachyKit
import ReachySimulator

/// Finding a robot from the TV: the robots Bonjour lists, an address typed with the
/// Siri Remote, and the phone's own background sweep underneath both.
///
/// The sweep is `CandidateSweep`, shared with the phone, so the TV reconnects to the
/// last robot, retries known addresses when a robot is switched on later, never tries
/// one address twice in a pass, and stands down while somebody chooses (project rule 4
/// and `.claude/rules/networking.md`). In the simulator it also tries loopback, which is
/// how a `sim-daemon` on the same Mac is reached.
@MainActor
@Observable
final class TVConnectionModel {
    let session: RobotSession
    let browser: RobotBrowser
    private let sweep: CandidateSweep

    var typedAddress: String
    /// The robot the reader picked, while its address is resolved and dialled. The
    /// sweep's own attempts are not shown: they walk `idle → handshaking → idle` every
    /// ten seconds while nothing answers, and a spinner on that heartbeat would come
    /// and go under the reader's eyes.
    private(set) var picked: Pick?
    /// The picked robot's advert did not resolve to an address.
    private(set) var pickFailed = false
    /// The in-app simulated robot could not be built: its bundled description did not
    /// parse, which `BundledRobotGeometryTests` rules out at build time.
    private(set) var simulatorFailed = false

    enum Pick: Equatable {
        case service(String)
        case typedAddress
        case simulator
    }

    init(session: RobotSession, browser: RobotBrowser = RobotBrowser()) {
        self.session = session
        self.browser = browser
        sweep = CandidateSweep(session: session)
        typedAddress = KnownRobots.lastAddress?.displayString ?? ""
    }

    /// One row per robot. A daemon advertises `_reachy-mini._tcp`; `_http._tcp` is the
    /// legacy advert of an older one, and it carries no hardware id to match the two by,
    /// so it is listed only when no robot uses the current type.
    var robots: [RobotBrowser.DiscoveredService] {
        let current = browser.services.filter { $0.type == RobotBrowser.serviceTypes[0] }
        return current.isEmpty ? browser.services : current
    }

    var typedAddressIsValid: Bool {
        RobotAddress(parsing: typedAddress) != nil
    }

    func start() {
        browser.start()
        // A screenshot or a check of this screen, or of the simulator, must not be raced
        // by the sweep connecting to a robot on its own (`TVCaptureStage`).
        guard TVCaptureStage.current?.holdsSweep != true else { return }
        sweep.start()
    }

    func stop() {
        sweep.stop()
        browser.stop()
    }

    /// Hands newly listed robots to the sweep, which resolves and tries each once.
    func servicesChanged() {
        sweep.resolve(browser.services)
    }

    func connect(to service: RobotBrowser.DiscoveredService) async {
        sweep.standDown()
        picked = .service(service.id)
        pickFailed = false
        defer { picked = nil }
        guard let address = await BonjourResolver.resolve(service.endpoint) else {
            pickFailed = true
            return
        }
        await session.connect(to: address)
    }

    /// The phone's own simulated robot (`ReachySimulator`, "Start the simulator" there):
    /// no hardware, no network and no camera. It is how somebody with no robot tries the
    /// app — App Review included. The caller keeps the client, because a simulator runs
    /// until somebody calls `shutDown()`.
    func makeSimulator() -> SimulatedRobotClient? {
        sweep.standDown()
        let client = SimulatedRobotClient()
        simulatorFailed = client == nil
        return client
    }

    func connect(simulating client: SimulatedRobotClient) async {
        picked = .simulator
        pickFailed = false
        defer { picked = nil }
        await session.connect(simulating: client)
    }

    func connectToTypedAddress() async {
        guard let address = RobotAddress(parsing: typedAddress) else { return }
        sweep.standDown()
        picked = .typedAddress
        pickFailed = false
        defer { picked = nil }
        await session.connect(to: address)
    }
}
