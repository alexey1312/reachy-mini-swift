import Foundation
@testable import ReachyKit
import Testing

/// A daemon that answers the two questions a power-off plan asks, and counts how
/// often it was asked the second.
private final class PlanClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    struct Unreachable: Error {}

    enum Startup {
        case set(String?)
        /// A read that never answers — the robot dropped off, or the request timed out.
        case unanswered
    }

    private let lock = NSLock()
    private var statusCalls = 0
    private let startup: Startup
    private let state: Components.Schemas.DaemonState?

    /// `state: nil` is a status read that fails.
    init(startup: Startup, state: Components.Schemas.DaemonState? = .running) {
        self.startup = startup
        self.state = state
    }

    var statusReads: Int {
        lock.withLock { statusCalls }
    }

    func handshake() async throws -> RobotConnection.Handshake {
        throw Unreachable()
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        lock.withLock { statusCalls += 1 }
        guard let state else { throw Unreachable() }
        let backend = state == .running ? #"{"motor_control_mode":"enabled","error":null}"# : "null"
        let json = """
        {"robot_name":"testbot","state":"\(state.rawValue)","wireless_version":true,
         "desktop_app_daemon":false,"simulation_enabled":false,"mockup_sim_enabled":false,
         "backend_status":\(backend)}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func wakeUp() async throws -> String {
        throw Unreachable()
    }

    func gotoSleep() async throws -> String {
        throw Unreachable()
    }

    func startupApp() async throws -> String? {
        switch startup {
        case let .set(name): return name
        case .unanswered: throw URLError(.timedOut)
        }
    }
}

/// A daemon that speaks no apps at all, so it cannot have a startup app to keep.
private struct BareClient: RobotAPIClient {
    func handshake() async throws -> RobotConnection.Handshake {
        throw URLError(.unsupportedURL)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        throw URLError(.unsupportedURL)
    }

    func wakeUp() async throws -> String {
        throw URLError(.unsupportedURL)
    }

    func gotoSleep() async throws -> String {
        throw URLError(.unsupportedURL)
    }
}

@Suite("Power off plan")
struct PowerOffPlanTests {
    @Test("a startup app on a running backend is slept rather than torn down")
    func keepsTheBackendForAStartupApp() {
        #expect(PowerOffPlan(startupApp: "dance", isBackendRunning: true) == .sleep(keepingStartupApp: "dance"))
    }

    @Test("with no startup app, powering off is the teardown it always was")
    func noStartupAppIsATeardown() {
        #expect(PowerOffPlan(startupApp: nil, isBackendRunning: true) == .stopBackend)
        #expect(PowerOffPlan(startupApp: "", isBackendRunning: true) == .stopBackend)
    }

    /// There is no watcher left to keep, and `move/play/goto_sleep` sits behind
    /// `get_backend` — a sleep would only be refused with a 503.
    @Test("a backend that is already down is planned the old way")
    func stoppedBackendIsATeardown() {
        #expect(PowerOffPlan(startupApp: "dance", isBackendRunning: false) == .stopBackend)
    }

    @Test("reads the startup app and the backend from the robot")
    func readsBothFacts() async {
        let running = PlanClient(startup: .set("dance"))
        #expect(await PowerOffPlan.read(from: running) == .sleep(keepingStartupApp: "dance"))

        let stopped = PlanClient(startup: .set("dance"), state: .stopped)
        #expect(await PowerOffPlan.read(from: stopped) == .stopBackend)
    }

    /// Every sequence that predates the plan keeps its shape: a robot with no
    /// startup app costs the one request and not a status read on top.
    @Test("no startup app costs no status read")
    func noStartupAppSkipsTheStatus() async {
        let client = PlanClient(startup: .set(nil))
        #expect(await PowerOffPlan.read(from: client) == .stopBackend)
        #expect(client.statusReads == 0)
    }

    /// Nothing is known to be worth keeping, so powering off stays what it was —
    /// and a client that cannot ask at all keeps the refusal it always gave.
    @Test("an unanswered startup-app read is torn down as before")
    func unansweredReadIsATeardown() async {
        let client = PlanClient(startup: .unanswered)
        #expect(await PowerOffPlan.read(from: client) == .stopBackend)
        #expect(client.statusReads == 0)
        #expect(await PowerOffPlan.read(from: BareClient()) == .stopBackend)
    }

    /// The two mistakes are not the same size: a sleep at a stopped backend is
    /// refused out loud and changes nothing, a teardown at a running one silently
    /// switches the antenna off.
    @Test("a status that cannot be read errs towards keeping the backend")
    func unreadableStatusSleeps() async {
        let client = PlanClient(startup: .set("dance"), state: nil)
        #expect(await PowerOffPlan.read(from: client) == .sleep(keepingStartupApp: "dance"))
        #expect(client.statusReads == 1)
    }
}
