import Foundation

/// Bounds how fast an emitted target may walk toward its goal.
///
/// A plain rate limit stretches a step out in time but leaves velocity
/// discontinuous at both ends, which still reads as a jerk. The exponential term
/// takes over as the error shrinks, so the movement decelerates into the goal.
///
/// Safety limits stay in the daemon (project rule 2): this bounds the speed of
/// approach, never the target itself.
public struct TargetSlewLimiter: Sendable, Equatable {
    /// Time constant of the exponential approach.
    public var tau: Duration
    /// Radians per second.
    public var headAngularRate: Double
    public var bodyYawRate: Double
    public var antennaRate: Double
    /// Meters per second.
    public var translationRate: Double

    public init(
        tau: Duration = .milliseconds(100),
        headAngularRate: Double = 90 * .pi / 180,
        bodyYawRate: Double = 120 * .pi / 180,
        antennaRate: Double = 240 * .pi / 180,
        translationRate: Double = 0.05
    ) {
        self.tau = tau
        self.headAngularRate = headAngularRate
        self.bodyYawRate = bodyYawRate
        self.antennaRate = antennaRate
        self.translationRate = translationRate
    }

    /// For a head that follows the reader's own (`HeadphoneTeleop`).
    ///
    /// The default is tuned for a thumb, whose jumps need smoothing. A head turns at
    /// 200–300°/s, and under the default's 90°/s and 100 ms time constant the robot
    /// was about half a second behind a quick turn on the first device run. A head
    /// also arrives already smooth, about 25 readings a second, so there is less to
    /// smooth. The other axes keep their defaults, because a head drives none of them.
    public static let headTracking = TargetSlewLimiter(
        tau: .milliseconds(35),
        headAngularRate: 240 * .pi / 180
    )

    /// Computed rather than stored: a key-path array is not `Sendable`, and a
    /// global one would need `nonisolated(unsafe)` to compile.
    static var axes: [(WritableKeyPath<SetTargetClient.Target, Double>, KeyPath<TargetSlewLimiter, Double>)] {
        [
            (\.x, \.translationRate),
            (\.y, \.translationRate),
            (\.z, \.translationRate),
            (\.roll, \.headAngularRate),
            (\.pitch, \.headAngularRate),
            (\.yaw, \.headAngularRate),
            (\.bodyYaw, \.bodyYawRate),
            (\.antennaLeft, \.antennaRate),
            (\.antennaRight, \.antennaRate),
        ]
    }

    private static let epsilon = 1e-5

    public func next(
        current: SetTargetClient.Target,
        goal: SetTargetClient.Target,
        dt: Duration
    ) -> SetTargetClient.Target {
        let seconds = dt.inSeconds
        guard seconds > 0 else { return current }
        let ease = 1 - exp(-seconds / tau.inSeconds)
        var next = current
        for (axis, rate) in Self.axes {
            let limit = self[keyPath: rate] * seconds
            let delta = (goal[keyPath: axis] - current[keyPath: axis]) * ease
            next[keyPath: axis] = current[keyPath: axis] + delta.clamped(to: -limit ... limit)
        }
        return next
    }

    public func hasConverged(_ a: SetTargetClient.Target, to b: SetTargetClient.Target) -> Bool {
        Self.axes.allSatisfy { abs(a[keyPath: $0.0] - b[keyPath: $0.0]) < Self.epsilon }
    }
}

extension Duration {
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
