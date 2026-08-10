import Foundation

/// Every duration and count `RobotSession` runs on, and what fixes each one.
///
/// In a file of its own for the reason `RunningAppModel.Configuration` is:
/// `RobotSession` reached SwiftLint's length limit, and this is the half that is
/// values rather than behaviour — eleven budgets, none of which does anything.
/// `RobotPower`, `RobotAppRelease` and every intent-side protocol take one too, so
/// it is also the piece with the most readers outside the session.
///
/// A nested type does not inherit the enclosing class's `@MainActor`, in an
/// extension or in the body, which is what lets a nonisolated `RobotPower` hold one.
public extension RobotSession {
    struct Configuration: Sendable {
        /// Upstream polls every 3 s (5 s over robot Wi-Fi).
        public var pollInterval: Duration = .seconds(3)
        /// Consecutive successful probes required to leave `.unreachable`.
        public var requiredConsecutiveSuccesses = 2
        /// Move task polling is intentionally cheaper than rendering/state streaming.
        public var movePollInterval: Duration = .milliseconds(500)
        /// Upstream waits this long for a wake/sleep animation before moving on.
        public var moveCompletionTimeout: Duration = .seconds(10)
        /// How long the robot takes to walk back to its zero pose after a move.
        ///
        /// Seconds rather than a `Duration` because `/api/move/goto` takes a number
        /// of seconds and this value is passed through to it unchanged. Long enough
        /// not to snap out of a dance, short enough that the next tap is not left
        /// waiting on it — `_try_start_move` refuses a play while it runs.
        public var recentreDuration: TimeInterval = 1.0
        /// Backend startup budget — upstream's `STARTUP.TIMEOUT_NORMAL`.
        public var daemonStartTimeout: Duration = .seconds(90)
        /// Shutdown budget. Shorter than the start, and not by guesswork: the
        /// daemon's teardown is the sleep animation plus a backend thread it joins
        /// with a 5 s cap, where a start builds a media pipeline and loads a model.
        public var daemonStopTimeout: Duration = .seconds(60)
        /// Motors need a moment to hold their pose before the animation starts.
        public var motorSettleDelay: Duration = .milliseconds(300)
        /// How long the app holding the robot may take to let go before it is
        /// parked anyway.
        ///
        /// The daemon gives the app 20 s to honour SIGINT and then kills it
        /// (`apps/manager.py:301`) and returns the robot to zero after that, so a
        /// normal stop is over in seconds and a stubborn one in twenty-odd. 30 s
        /// clears both. Anything past it is the daemon's one-way `stopping` wedge,
        /// which no client can open — and holding the head up for it would be the
        /// worse answer.
        public var appStopTimeout: Duration = .seconds(30)
        /// Upstream's job-polling cadence, for the same reason it uses it: somebody
        /// is watching their robot and waiting for it to move.
        public var appStopPollInterval: Duration = .milliseconds(500)
        /// Connect-time readiness budget. We never start a backend during connect,
        /// so a stopped one is reported at once — this only covers the window
        /// between `state == running` and `backend.ready`.
        public var readinessTimeout: Duration = .seconds(8)
        public var readinessPollInterval: Duration = .milliseconds(500)

        public init() {}
    }
}
