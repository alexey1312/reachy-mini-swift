import Foundation

/// The four routes power runs through, and the two that take the backend with it.
///
/// Split from `RobotConnection` the way `RobotSession+Power` is split from its
/// session: these are the routes a transition is assembled from, and none of them
/// is a transition on its own. The protocols that order them live one layer up, in
/// `RobotPower` and `RobotSession+Power`.
public extension RobotConnection {
    /// Plays the wake-up animation. Motors must already be enabled — the daemon
    /// route does not touch the control mode, so a `disabled` robot just doesn't move.
    ///
    /// Status codes are mapped explicitly: `.ok` would surface the daemon's 503
    /// "Backend not running" as an opaque `undocumented` runtime error.
    func wakeUp() async throws -> String {
        switch try await client.playWakeUpApiMovePlayWakeUpPost() {
        case let .ok(response):
            try response.body.json.uuid
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    func gotoSleep() async throws -> String {
        switch try await client.playGotoSleepApiMovePlayGotoSleepPost() {
        case let .ok(response):
            try response.body.json.uuid
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// From daemon 1.13.0 a mode the robot cannot enter answers 409 with a `detail`:
    /// gravity compensation needs Placo, which stock Wireless robots lack
    /// (pollen-robotics/reachy_mini#1454). That is not the busy daemon a 409 means
    /// everywhere else, so the sentence is kept rather than classified away.
    func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        switch try await client.setMotorModeApiMotorsSetModeModePost(path: .init(mode: mode)) {
        case .ok:
            return
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, payload):
            if statusCode == 409, let detail = await Self.detail(of: payload) {
                throw ReachyKitError.daemonRefused(statusCode: 409, detail: detail)
            }
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    func motorMode() async throws -> Components.Schemas.MotorControlMode {
        try await client.getMotorStatusApiMotorsStatusGet().ok.body.json.mode
    }

    /// Starts the robot backend. Returns immediately with a job id — the caller
    /// must poll `daemonStatus()` until the state settles.
    func startDaemon(wakeUp: Bool) async throws {
        switch try await client.startDaemonApiDaemonStartPost(query: .init(wakeUp: wakeUp)) {
        case .ok:
            return
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// Tears the robot backend down, leaving the daemon's own HTTP server up — so
    /// `daemonStatus()` keeps answering and `startDaemon` is the way back.
    ///
    /// A background job like its mirror image, so this returns as soon as the
    /// daemon has accepted it and the caller polls. `gotoSleep` is what makes the
    /// shutdown graceful, and the daemon does more with it than this client could:
    /// it enables the motors, *awaits* the sleep animation, and only then cuts
    /// power. 409 means another daemon job is already running.
    ///
    /// It does **not** stop the running app: the daemon's teardown drops the media
    /// server and the JSON-RPC relay and never touches the app manager, so an app
    /// left running has its backend go out from under it. That guard belongs to the
    /// caller — `RobotSession.powerOff` is where it lives.
    func stopDaemon(gotoSleep: Bool) async throws {
        switch try await client.stopDaemonApiDaemonStopPost(query: .init(gotoSleep: gotoSleep)) {
        case .ok:
            return
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }
}
