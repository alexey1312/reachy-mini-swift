import Foundation
import ReachyJSON
import ReachyKit

/// What a tap did, for a widget that will be redrawn by a different process than
/// the one that ran it.
///
/// A widget has no spinner it can hold across that boundary and no way to be told
/// an intent failed: `perform()` runs in the extension, throws into nothing a user
/// can see, and the process ends. So the intent writes down what it is doing and
/// what came of it, and the next render reads it back.
///
/// This lives in `ReachyWidgetUI` rather than in `ReachyKit` because it is purely
/// the widget's own bookkeeping — nothing in the app reads it.
public struct RobotAppLaunchState: Codable, Sendable, Equatable {
    /// A tap that has not come back yet.
    public struct Pending: Codable, Sendable, Equatable {
        public let appID: String
        /// Which caption to show. A stop is not a start that happens to end
        /// differently.
        public let isStop: Bool
        public let since: Date

        public init(appID: String, isStop: Bool, since: Date) {
            self.appID = appID
            self.isStop = isStop
            self.since = since
        }
    }

    public struct Failure: Codable, Sendable, Equatable {
        public let appID: String
        /// The daemon's own sentence, by way of `RobotSession.describe`.
        public let message: String
        public let at: Date

        public init(appID: String, message: String, at: Date) {
            self.appID = appID
            self.message = message
            self.at = at
        }
    }

    /// Past this a launch is assumed lost rather than slow — the extension can be
    /// killed mid-call, and then nothing would ever clear the caption. Generous
    /// enough to cover a wake animation plus a daemon taking its time.
    public static let pendingWindow: TimeInterval = 90
    /// How long a failure is still worth reporting. Past it the user has moved on,
    /// and a widget still apologising for this morning is noise.
    public static let failureWindow: TimeInterval = 15 * 60

    public let pending: Pending?
    public let failure: Failure?

    public init(pending: Pending? = nil, failure: Failure? = nil) {
        self.pending = pending
        self.failure = failure
    }

    public func pending(at date: Date) -> Pending? {
        guard let pending, date.timeIntervalSince(pending.since) <= Self.pendingWindow else { return nil }
        return pending
    }

    public func failure(at date: Date) -> Failure? {
        guard let failure, date.timeIntervalSince(failure.at) <= Self.failureWindow else { return nil }
        return failure
    }
}

/// The launch state, in storage both processes can reach.
public struct RobotAppLaunchStateStore {
    static let key = "ReachyWidgetUI.appLaunchState"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    public var current: RobotAppLaunchState? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONCodec.stored.decode(RobotAppLaunchState.self, from: data)
    }

    /// Clears any earlier failure: the user has just retried, and showing them why
    /// the last attempt failed while this one is in flight reads as this one
    /// failing.
    public func begin(appID: String, isStop: Bool, at date: Date = Date()) {
        write(RobotAppLaunchState(
            pending: .init(appID: appID, isStop: isStop, since: date),
            failure: nil
        ))
    }

    public func succeed(appID: String) {
        guard current?.pending?.appID == appID || current?.failure?.appID == appID else { return }
        write(RobotAppLaunchState())
    }

    public func fail(appID: String, message: String, at date: Date = Date()) {
        write(RobotAppLaunchState(
            pending: nil,
            failure: .init(appID: appID, message: message, at: date)
        ))
    }

    private func write(_ state: RobotAppLaunchState) {
        guard let data = try? JSONCodec.stored.encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
