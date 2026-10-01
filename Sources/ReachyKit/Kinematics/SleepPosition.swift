import Foundation

/// The nine motors a sleep-position check can name, in the order the robot reports
/// them: `head_joint_positions` is the base and then the six neck motors, and
/// `antennas` is the right one and then the left — the motor controller's ids 10 to
/// 18 (`assets/config/hardware_config.yaml`).
public enum RobotMotor: Int, CaseIterable, Sendable, Hashable {
    case base
    case neck1, neck2, neck3, neck4, neck5, neck6
    case rightAntenna, leftAntenna
}

/// A pair of motors reading each other's position: two cables in each other's
/// sockets, which is what a robot assembled at home gets wrong.
public struct MotorSwap: Equatable, Sendable {
    public let first: RobotMotor
    public let second: RobotMotor

    public init(_ first: RobotMotor, _ second: RobotMotor) {
        self.first = first
        self.second = second
    }
}

/// Whether a limp robot is lying in its sleep pose, motor by motor (#169).
///
/// **This is the one check that can see a wiring mistake before the motors are
/// powered.** Waking a robot with two motors swapped drives each one to the other's
/// target; lying limp it merely reads wrong. So the first run runs this while the
/// robot is still asleep and holds the wake-up until it passes, as Pollen's mobile
/// app does.
///
/// - **The targets are the cranks that hold `SLEEP_HEAD_POSE`**, the daemon's own
///   sleep matrix (`daemon/backend/abstract.py`), not its `SLEEP_HEAD_JOINT_POSITIONS`
///   list: that one is a more forward-tilted pose, some 47° away on two neck motors,
///   and a limp head settles on the pose `goto_sleep` put it in. Pollen's mobile app
///   (0.11.2) checks the same values; `SleepPositionTests` re-derives them from the
///   matrix through this client's own `StewartIK`, so the numbers here are a cache of
///   that solve rather than something copied.
/// - **The tolerances are generous on purpose** — 0.35 rad on the base and the
///   antennas, 0.55 on the neck, the mobile app's figures — because a limp head sags
///   and the question is "is something wired wrong", not "is it precise". Once in
///   position every band widens by 0.12 rad, so a robot right at an edge does not
///   flicker in and out of it.
/// - **A swap is two motors each well away from their own target and each close to
///   the other's** — the desktop wizard's rule (reachy-mini-desktop-app#225), 15° both
///   ways. It is only looked for once something is out of place.
public enum SleepPosition {
    public enum Reading: Equatable, Sendable {
        /// The robot sent no motor-by-motor pose — a daemon before 1.10.0, or no frame
        /// yet. Nothing to hold anything on.
        case unavailable
        case inPosition
        case outOfPosition(misplaced: [RobotMotor], swaps: [MotorSwap])

        public var isInPosition: Bool {
            self == .inPosition
        }
    }

    /// Radians, in ``RobotMotor`` order.
    static let target: [Double] = [
        0, -0.17062, 0.83649, -0.12343, 0.08757, -0.81217, 0.17851,
        -3.05, 3.05,
    ]

    static let baseTolerance = 0.35
    static let neckTolerance = 0.55
    static let antennaTolerance = 0.35
    /// Added to every band while the robot reads in position.
    static let hysteresis = 0.12
    /// 15°, both ways.
    static let swapTolerance = 15 * Double.pi / 180

    public static func reading(
        headJoints: [Double]?,
        antennas: [Double]?,
        wasInPosition: Bool = false
    ) -> Reading {
        guard let headJoints, headJoints.count == 7, let antennas, antennas.count == 2 else {
            return .unavailable
        }
        let actual = headJoints + antennas
        let slack = wasInPosition ? hysteresis : 0
        let misplaced = RobotMotor.allCases.filter { motor in
            abs(actual[motor.rawValue] - target[motor.rawValue]) > tolerance(for: motor) + slack
        }
        guard !misplaced.isEmpty else { return .inPosition }
        return .outOfPosition(misplaced: misplaced, swaps: swaps(in: actual))
    }

    static func tolerance(for motor: RobotMotor) -> Double {
        switch motor {
        case .base: baseTolerance
        case .neck1, .neck2, .neck3, .neck4, .neck5, .neck6: neckTolerance
        case .rightAntenna, .leftAntenna: antennaTolerance
        }
    }

    private static func swaps(in actual: [Double]) -> [MotorSwap] {
        let motors = RobotMotor.allCases
        var found: [MotorSwap] = []
        for (index, first) in motors.enumerated() {
            for second in motors[(index + 1)...] where reads(first, as: second, actual) {
                found.append(MotorSwap(first, second))
            }
        }
        return found
    }

    private static func reads(_ first: RobotMotor, as second: RobotMotor, _ actual: [Double]) -> Bool {
        let one = first.rawValue
        let other = second.rawValue
        return abs(actual[one] - target[one]) >= swapTolerance
            && abs(actual[other] - target[other]) >= swapTolerance
            && abs(actual[one] - target[other]) < swapTolerance
            && abs(actual[other] - target[one]) < swapTolerance
    }
}
