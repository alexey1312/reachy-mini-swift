import Foundation
import ReachyJSON
import ReachyKit

/// What a power tap is doing, for a widget that will be redrawn by a different
/// process than the one that ran it.
///
/// The twin of `RobotAppLaunchState`, and it exists for a sharper reason than that
/// one did. `RobotPower.resume()` **deliberately does not wait**: a cold backend
/// start is budgeted at 90 s and an intent has seconds, so it returns the moment
/// the daemon accepts the job. WidgetKit's own `invalidatableContent` dimming
/// lasts only while `perform()` runs in this process — about a second of those
/// ninety. Without something durable the widget would go straight back to saying
/// "Asleep" under an unchanged Wake up button, which is the "tap it again" bug
/// this whole surface exists to avoid.
public struct RobotPowerTransitionState: Codable, Sendable, Equatable {
    /// A tap that has not come back yet.
    public struct Pending: Codable, Sendable, Equatable {
        public let transition: RobotSession.PowerTransition
        public let since: Date

        public init(transition: RobotSession.PowerTransition, since: Date) {
            self.transition = transition
            self.since = since
        }
    }

    public struct Failure: Codable, Sendable, Equatable {
        /// The daemon's own sentence, by way of `RobotSession.describe`.
        public let message: String
        public let at: Date

        public init(message: String, at: Date) {
            self.message = message
            self.at = at
        }
    }

    /// Per transition, because the budgets differ by an order of magnitude and one
    /// window would be wrong twice — too short to cover a cold start, or long
    /// enough to leave "Going to sleep…" up for two minutes after a four-second
    /// operation.
    ///
    /// Each is its measured budget plus headroom for the round trips around it.
    /// The headroom is a judgement; the budgets are not.
    public static func window(for transition: RobotSession.PowerTransition) -> TimeInterval {
        switch transition {
        // The 90 s cold start `RobotPower.resume()` names, plus the wake animation
        // the daemon plays itself once the backend is up.
        case .startingBackend: 120
        // `stopDaemon` returns on job acceptance; the robot then sleeps and tears
        // the backend down behind it.
        case .stoppingBackend: 60
        // `widgetIntent.moveCompletionTimeout` is 4 s.
        case .wakingUp: 30
        // `appStopTimeout` 6 s, then the animation's 4 s, then `set_mode`.
        case .goingToSleep: 45
        }
    }

    /// Deliberately the launcher's constant rather than a second one beside it: two
    /// independent numbers that happen to be equal drift the first time one is
    /// tuned, and a widget apologising for this morning is noise either way.
    public static var failureWindow: TimeInterval {
        RobotAppLaunchState.failureWindow
    }

    public let pending: Pending?
    public let failure: Failure?

    public init(pending: Pending? = nil, failure: Failure? = nil) {
        self.pending = pending
        self.failure = failure
    }

    public func pending(at date: Date) -> Pending? {
        guard let pending,
              date.timeIntervalSince(pending.since) <= Self.window(for: pending.transition)
        else { return nil }
        return pending
    }

    public func failure(at date: Date) -> Failure? {
        guard let failure, date.timeIntervalSince(failure.at) <= Self.failureWindow else { return nil }
        return failure
    }
}

/// The transition state, in storage both processes can reach.
public struct RobotPowerTransitionStore {
    static let key = "ReachyWidgetUI.powerTransition"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    public var current: RobotPowerTransitionState? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONCodec.stored.decode(RobotPowerTransitionState.self, from: data)
    }

    /// Clears any earlier failure, for the reason `RobotAppLaunchStateStore.begin`
    /// does: the user has just retried, and why the last attempt failed reads as
    /// this one failing while it is still in flight.
    public func begin(_ transition: RobotSession.PowerTransition, at date: Date = Date()) {
        write(RobotPowerTransitionState(pending: .init(transition: transition, since: date), failure: nil))
    }

    public func succeed() {
        write(RobotPowerTransitionState())
    }

    public func fail(message: String, at date: Date = Date()) {
        write(RobotPowerTransitionState(pending: nil, failure: .init(message: message, at: date)))
    }

    private func write(_ state: RobotPowerTransitionState) {
        guard let data = try? JSONCodec.stored.encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
