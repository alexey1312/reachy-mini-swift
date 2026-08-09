import Foundation

/// The wake and sleep protocols, with no session around them.
///
/// `RobotSession` owns them for the app, where a failure belongs on a screen and
/// a transition has to be latched against a double tap. An App Intent has neither
/// a screen nor a second tap to guard against — it has seconds, one client, and a
/// caller that needs to be told what happened. So the protocol itself lives here
/// and both callers share it, rather than the sequence existing twice and drifting.
///
/// Neither transition is a single call: `/move/play/*` only plays an animation and
/// never touches the motor control mode, so enabling and cutting power is the
/// caller's job — and the order is what keeps the robot's head off the desk.
///
/// `wake()` and `resume()` are two different promises and both are wanted:
/// `wake()` is the motor protocol and assumes a backend, `resume()` is what a
/// user means by "wake up" when the backend may be gone.
public struct RobotPower: Sendable {
    /// What waking had to do to get there. The two answers are different news for
    /// a caller with one sentence to speak: one of them means the robot is awake
    /// now, the other that it will be shortly.
    public enum Resumption: Equatable, Sendable {
        /// The backend was up, so this was the ordinary wake protocol.
        case woke
        /// The backend was down and has been asked to come back with
        /// `wake_up=true`. Nothing was waited on — see `resume()`.
        case startingBackend
    }

    private let client: any RobotAPIClient
    private let configuration: RobotSession.Configuration

    public init(client: any RobotAPIClient, configuration: RobotSession.Configuration = .init()) {
        self.client = client
        self.configuration = configuration
    }

    /// Motors first, then the animation. An asleep robot accepts the play route,
    /// makes the sound and does not move, which reads as the robot ignoring you.
    public func wake() async throws {
        try await client.setMotorMode(.enabled)
        try await Task.sleep(for: configuration.motorSettleDelay)
        let uuid = try await client.wakeUp()
        await waitForMoveToFinish(uuid)
    }

    /// Wake, bringing the robot backend back first when it is gone.
    ///
    /// **`wake()` alone cannot do this, and that is what made the ladder
    /// one-directional.** `motors/set_mode` sits behind `get_backend` and answers
    /// 503 the moment the backend is torn down — which is exactly the state
    /// `RobotShutdown` leaves the robot in, so powering off from Shortcuts or
    /// Control Centre worked while waking up afterwards could not. Only
    /// `RobotSession.wake()` knew to start the backend first, and that one needs
    /// the app on screen.
    ///
    /// **Nothing is polled.** A cold backend start is budgeted at 90 s and an
    /// intent has seconds, so this returns as soon as the daemon has accepted the
    /// job — `wake_up=true` has the daemon enable the motors and play the animation
    /// itself once the backend is up, so the robot still ends up awake with no
    /// second command. The caller says which of the two happened rather than
    /// claiming a robot that is still starting is already awake.
    @discardableResult
    public func resume() async throws -> Resumption {
        switch try await client.daemonStatus().state {
        case .running:
            try await wake()
            return .woke
        case .starting:
            // A second `daemon/start` answers 409 while a job runs, so the honest
            // answer is the one already in flight.
            return .startingBackend
        default:
            try await startBackendWaking()
            return .startingBackend
        }
    }

    /// `daemon/start?wake_up=true` and nothing else, for a caller that has already
    /// established the backend is down and does not want the status read twice.
    public func startBackendWaking() async throws {
        try await client.startDaemon(wakeUp: true)
    }

    /// The animation must finish *before* power is cut, otherwise the head drops
    /// wherever it happens to be.
    public func sleep() async throws {
        let uuid = try await client.gotoSleep()
        await waitForMoveToFinish(uuid)
        try await client.setMotorMode(.disabled)
    }

    /// Polls the daemon's own running-move list until the id is gone.
    ///
    /// A timeout returns normally rather than throwing: parking the motors matters
    /// more than proof the animation ran to the end, and a remote connection
    /// reports no running moves at all by construction.
    private func waitForMoveToFinish(_ uuid: String) async {
        let deadline = ContinuousClock.now + configuration.moveCompletionTimeout
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return }
            guard let running = try? await client.runningMoveUUIDs() else { return }
            if !running.contains(uuid) {
                return
            }
            try? await Task.sleep(for: configuration.movePollInterval)
        }
    }
}
