import Foundation
import ReachyDesign
import ReachyKit

/// Starting and stopping one app, with no session around it.
///
/// `RobotSession` owns this for the app, where a failure belongs on a screen and
/// the store's own list is already loaded. A widget tap has neither: it has
/// seconds, one client, and a caller that has to be told what happened. So the
/// protocol lives here and every caller without a screen shares it — the widget's
/// tile and Shortcuts' three actions — rather than the sequence existing four
/// times and drifting. The same reason `RobotPower` and `RobotShutdown` exist.
///
/// `toggle` is what a button wants and `start` / `stop` are what an automation
/// wants: a shortcut says what it wants rather than what it wants flipped.
public struct RobotAppLauncher: Sendable {
    /// What the robot did, in the daemon's own vocabulary and no other.
    ///
    /// **`title` is not a title on a real robot**, which is why only `.started`
    /// carries one and only the snapshot store reads it. Every reply this layer
    /// sees — `current-app-status`, `start-app` — is built with an empty `extra`,
    /// so `RobotApp.title` falls back to the entry point name. A caller with a
    /// sentence to speak joins the real one back through `RobotAppTitles`; nothing
    /// here embellishes what the daemon said.
    public enum Outcome: Equatable, Sendable {
        case started(name: String, title: String)
        case stopped(name: String)
    }

    /// The two ways a command refuses before the robot is even asked to do
    /// anything. Both are phrased as what the user can do, because a widget shows
    /// this sentence and nothing else.
    public enum Failure: Error, LocalizedError, Equatable {
        /// Another app holds the robot. `start-app` would evict it silently, and a
        /// widget is the wrong place to take that decision on someone's behalf.
        case busy(title: String)
        /// A `/` would split the `start-app` path into segments and 404. No Python
        /// entry point can contain one, so this turns an inexplicable failure into
        /// a legible one rather than guarding a real case.
        case unusableName(String)

        public var errorDescription: String? {
            switch self {
            case let .busy(title):
                String(localized: .reachy("“\(title)” is running. Stop it first."))
            case let .unusableName(name):
                String(localized: .reachy("“\(name)” can't be started from here. Open Reachy Mini and start it there."))
            }
        }
    }

    private let apps: any RobotAppsClient
    private let power: RobotPower
    private let isAwake: @Sendable () async throws -> Bool

    /// `assumeAwake` skips the readiness round trip when the caller already holds a
    /// reading worth trusting; nil asks the daemon.
    public init(
        client: any RobotAPIClient & RobotAppsClient,
        configuration: RobotSession.Configuration = .widgetIntent,
        assumeAwake: Bool?
    ) {
        apps = client
        power = RobotPower(client: client, configuration: configuration)
        isAwake = {
            if let assumeAwake {
                return assumeAwake
            }
            return try await client.daemonStatus().isAwake
        }
    }

    /// Test seam: the three things this needs, with no client to build them from.
    init(
        apps: any RobotAppsClient,
        power: RobotPower,
        isAwake: @escaping @Sendable () async throws -> Bool
    ) {
        self.apps = apps
        self.power = power
        self.isAwake = isAwake
    }

    /// Starts `name`, or stops it if it is what the robot is already running.
    public func toggle(name: String) async throws -> Outcome {
        try refuseUnusable(name)

        if let running = try await runningApp() {
            guard running.app.name == name else { throw Failure.busy(title: running.app.title) }
            try await apps.stopCurrentApp()
            return .stopped(name: name)
        }
        return try await startFreeRobot(named: name)
    }

    /// Starts `name` and leaves it running.
    ///
    /// An app that is already the one running is a success rather than a refusal:
    /// an automation asking for it means "see that this is on", and going red at a
    /// robot that is already doing the thing would be the wrong answer to the right
    /// question. Another app holding the robot is still `Failure.busy` — that one
    /// is a decision, not a state.
    public func start(name: String) async throws -> Outcome {
        try refuseUnusable(name)

        if let running = try await runningApp() {
            guard running.app.name == name else { throw Failure.busy(title: running.app.title) }
            return .started(name: name, title: running.app.title)
        }
        return try await startFreeRobot(named: name)
    }

    /// Stops whatever holds the robot, whichever app that is.
    ///
    /// `nil` when nothing was running, and that is not a failure either: an
    /// automation ending by clearing the robot should not report one because the
    /// robot was already clear. Nothing here wakes it — stopping a process needs no
    /// motors.
    public func stop() async throws -> Outcome? {
        guard let running = try await runningApp() else { return nil }
        try await apps.stopCurrentApp()
        return .stopped(name: running.app.name)
    }

    /// A `/` would split the `start-app` path into segments and 404, so it is
    /// refused before anything is sent.
    private func refuseUnusable(_ name: String) throws {
        guard name.contains("/") else { return }
        throw Failure.unusableName(name)
    }

    /// The one reading every path starts from, and each path reads it exactly once.
    ///
    /// Asked afresh, never assumed from a snapshot: a reading can be half an hour
    /// old, and this is the only thing standing between a tap and evicting somebody
    /// else's app. The daemon has no way to refuse that for us —
    /// `start-app/{app}/no-evict` is in the spec but 1.9.0 does not mount it. An
    /// app that finished is not an app holding the robot.
    private func runningApp() async throws -> RobotAppStatus? {
        guard let running = try await apps.currentAppStatus(), running.isBusy else { return nil }
        return running
    }

    /// Everything after the robot has been found free.
    private func startFreeRobot(named name: String) async throws -> Outcome {
        // No check on the backend first: every `motors/*` route sits behind
        // `get_backend` and answers 503 at once when it is down, which reads as a
        // sentence. Starting the backend from here would be a ninety-second job in
        // a process that has seconds.
        if try await isAwake() == false {
            try await power.wake()
        }

        try Task.checkCancellation()
        let started = try await apps.startApp(named: name)
        return .started(name: name, title: started.app.title)
    }
}

public extension RobotSession.Configuration {
    /// A widget intent runs on a budget the wake animation would eat whole.
    ///
    /// Safe to cut: `RobotPower.waitForMoveToFinish` returns normally when its
    /// deadline passes rather than throwing, so a shorter one means the app starts
    /// while the robot is still finishing its stretch — not that anything fails.
    ///
    /// `appStopTimeout` is cut for the same reason and is the same kind of trade,
    /// but not the same size of one: a stop that outruns six seconds leaves the
    /// parking to land on a robot the app is still handing back, which is exactly
    /// what the wait is for. It is still the right cut — an intent killed halfway
    /// through a thirty-second wait leaves the robot awake with its app already
    /// gone, and nothing written down anywhere.
    static var widgetIntent: Self {
        var configuration = Self()
        configuration.moveCompletionTimeout = .seconds(4)
        configuration.appStopTimeout = .seconds(6)
        return configuration
    }
}
