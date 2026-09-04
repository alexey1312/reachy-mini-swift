import AppIntents
import ReachyDesign
import ReachyKit

/// Why an intent can fail before it ever reaches a robot.
///
/// Shortcuts shows this text and nothing else, so each case has to say what the
/// user can do about it rather than what went wrong internally.
public enum RobotIntentError: Error, LocalizedError, Equatable {
    case noKnownRobot
    case wrongRobot
    case unsupportedDaemon(String)
    case timedOut
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .noKnownRobot:
            "No robot to reach. Open Reachy Mini and connect to one first."
        case .wrongRobot:
            "That address belongs to a different Reachy Mini. Open Reachy Mini to reconnect."
        case let .unsupportedDaemon(message):
            message
        case .timedOut:
            "The robot took too long to answer. Open Reachy Mini and try again."
        case let .unreachable(reason):
            reason
        }
    }
}

/// The robot an intent acts on: the one it named, or the last one this app
/// connected to, at the address that robot answered on.
///
/// **Local network only, deliberately.** A robot reached through the Hugging Face
/// relay needs a WebRTC session negotiated over a signalling stream, and an intent
/// does not have the time budget for that — it would sit there and then fail. Away
/// from the robot's network this fails immediately and says so, which is the
/// honest outcome rather than a slow one.
public enum RobotIntentTarget {
    public struct VerifiedConnection: Sendable {
        public let robot: KnownRobot
        public let client: RobotConnection
    }

    /// The last completed handshake, including the stable identity an intent must
    /// verify before it sends a command to the remembered address.
    public static var knownRobot: KnownRobot? {
        knownRobot(id: nil)
    }

    /// The robot an intent named, looked up **now** rather than taken from the
    /// entity that named it.
    ///
    /// A `RobotEntity` is persisted inside a shortcut and carries the address the
    /// robot answered at when it was written; the same robot answers somewhere else
    /// tomorrow (project rule 4). So the entity contributes an identity and the
    /// store contributes an address, which is the split every other reader here
    /// already makes.
    ///
    /// A robot the app has since forgotten falls through to `.noKnownRobot` rather
    /// than to the first one in the list: a shortcut that silently retargets is
    /// worse than one that says it cannot run.
    public static func knownRobot(id: String?) -> KnownRobot? {
        let known = KnownRobots.all
        guard let id else { return known.first }
        return known.first { $0.key == id }
    }

    /// One connection whose every sub-session is capped at `timeout`.
    ///
    /// `RobotConnection` reuses an injected session for all of them, including the
    /// 35-second hub session that `/api/apps/*` normally runs on — which is the
    /// point here rather than a side effect. That budget exists for a screen with
    /// a spinner; an intent that sat on it would be killed with nothing written
    /// down.
    public static func connection(to id: String? = nil, timeout: TimeInterval) async throws -> VerifiedConnection {
        guard let robot = knownRobot(id: id) else {
            throw RobotIntentError.noKnownRobot
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        do {
            let connection = try RobotConnection(
                address: robot.address,
                session: URLSession(configuration: configuration)
            )
            let handshake = try await connection.handshake()
            try validate(handshake, expected: robot)
            return VerifiedConnection(robot: robot, client: connection)
        } catch let error as RobotIntentError {
            throw error
        } catch {
            throw RobotIntentError.unreachable(RobotSession.describe(error))
        }
    }

    static func validate(_ handshake: RobotConnection.Handshake, expected robot: KnownRobot) throws {
        guard handshake.identity.deduplicationKey == robot.key else {
            throw RobotIntentError.wrongRobot
        }
        if case let .unsupported(reported, minimum) = handshake.compatibility {
            throw RobotIntentError.unsupportedDaemon(
                "Daemon \(reported) is unsupported; version \(minimum) is required."
            )
        }
    }

    /// A request timeout bounds one period of inactivity. This bounds the entire
    /// multi-request intent, including the identity handshake and wake sequence.
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RobotIntentError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

/// The way back up from `PowerOffRobotIntent`, whose own description promises
/// exactly that — so this one starts the backend when it finds it down rather than
/// sending `motors/set_mode` at a robot that can only answer 503.
public struct WakeRobotIntent: AppIntent {
    public static let title: LocalizedStringResource = "Wake Reachy Mini"
    public static let description = IntentDescription(
        "Enables the robot's motors and plays its wake-up animation, starting its backend first if it is off."
    )
    // Runs in the background, which is the default and the only thing that works
    // here. `openAppWhenRun = true` would bring the app forward, but it is
    // deprecated *and* errors when the intent runs in an app extension — exactly
    // where a Control Centre button runs it. Its replacement, `supportedModes`,
    // is iOS 26 and this app deploys to 18.
    //
    // Background means the extension's own process, which cannot ask for Local
    // Network access: it has no screen to prompt from, and a denial there is
    // silent. Safe only because the intent already requires a robot this app has
    // connected to before, and that connection is what obtained the permission.

    /// Optional on every intent here, and that is what keeps the six existing Siri
    /// phrases working: an unfilled optional is not asked for, so "Wake up Hey
    /// Reachy" still means the last robot connected to. Naming one is the addition.
    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    /// Below iOS 27 the dialog is the whole of what a starting backend can be
    /// reported as: the job takes tens of seconds, this process has seconds, and a
    /// spinner nobody can see is worth less than a sentence saying the robot is on
    /// its way. On 27 the process can ask for those seconds — see `coldStart`.
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = RobotPowerCommand(.wake, robot: robot?.id)
        switch try await command.perform() {
        case .startingBackend:
            return await .result(dialog: coldStart(command))
        case .woke, .none:
            return .result(dialog: IntentDialog(.reachy("Reachy Mini is awake.")))
        }
    }

    /// What to say about a backend that was off, once the daemon has accepted the job.
    ///
    /// **iOS 27 is the first release where there is a second answer.** A backend start
    /// is budgeted at 90 s against an intent's 30, so every version of this until now
    /// has had to hand back a promise and leave the widget's marker to cover the rest.
    /// `LongRunningIntent.performBackgroundTask` extends that budget, which is exactly
    /// the case its own documentation names — so on 27 the intent waits, reports
    /// progress, and answers with what happened rather than with what was asked for.
    ///
    /// **Progress is not optional decoration here.** The system ends a background
    /// extension whose intent stops reporting, and it is the same value a Live
    /// Activity draws the bar from — which is why `RobotPower.waitForBackendRunning`
    /// reports once per poll and says outright that the fraction is of the *budget*,
    /// the daemon publishing nothing about how far along a start is.
    ///
    /// The local `let` is what the reporting closure captures, rather than `self`:
    /// `Progress` is `Sendable` (the compiler says so — an explicit
    /// `nonisolated(unsafe)` here is diagnosed as unnecessary) while an intent
    /// carrying a `RobotEntity?` is not, so capturing the intent would put a
    /// `Sendable` requirement on every parameter it grows.
    private func coldStart(_ command: RobotPowerCommand) async -> IntentDialog {
        let starting = IntentDialog(.reachy("Reachy Mini was off. It's starting up and will wake itself."))
        guard #available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *) else {
            return starting
        }
        let progress = progress
        progress.totalUnitCount = 100
        progress.localizedDescription = String(localized: .reachy("Starting Reachy Mini"))
        // `try?`: the only thing that throws here is the system refusing the
        // extension, and the honest answer to that is the sentence this method
        // would have given below 27 — the daemon has the job either way.
        let awake = try? await performBackgroundTask {
            await command.awaitStartedBackend { fraction in
                progress.completedUnitCount = Int64(fraction * 100)
            }
        }
        return awake == true ? IntentDialog(.reachy("Reachy Mini is awake.")) : starting
    }
}

/// The one job in this app that outlives an intent's budget.
///
/// `ExecutionTargets` and `CancellableIntent` were considered with it and refused;
/// `docs/research/ios-27.md` §3.1 carries both reasons, and the second one is this
/// app's own pending marker: it describes the *robot's* transition, which the daemon
/// owns and which outlives every process that asks for it, so a cancellation handler
/// has nothing true to write.
@available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)
extension WakeRobotIntent: LongRunningIntent {}

/// Sleeping takes the motors away from whatever is using them, so the app using
/// them is stopped first — see `RobotSleep`.
public struct SleepRobotIntent: AppIntent {
    public static let title: LocalizedStringResource = "Put Reachy Mini to sleep"
    public static let description = IntentDescription(
        "Stops the running app, plays the robot's sleep animation, then parks its motors."
    )

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await RobotPowerCommand(.sleep, robot: robot?.id).perform()
        return .result()
    }
}

/// Sleep's bigger sibling: the camera, the state stream and the motors all go
/// rather than only the motors.
///
/// Not behind a confirmation, unlike the button on the Robot screen. There is
/// nowhere to ask from — Siri and the Home Screen menu both run this with no
/// screen of their own — and the daemon's own HTTP server survives the teardown,
/// so waking up is the way back and nothing has to be reconnected.
public struct PowerOffRobotIntent: AppIntent {
    public static let title: LocalizedStringResource = "Power Reachy Mini off"
    public static let description = IntentDescription(
        "Stops the running app, puts the robot to sleep and shuts its backend down. Waking up brings it back."
    )

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await RobotPowerCommand(.powerOff, robot: robot?.id).perform()
        return .result()
    }
}
