import Foundation
@testable import ReachyKit
import Testing

/// The first run's sleep-position check (#169): which motors are out of place on a
/// limp robot, and which pairs read like each other's cables.
@Suite("Sleep position")
struct SleepPositionTests {
    /// `SLEEP_HEAD_POSE` from `daemon/backend/abstract.py`, row-major, metres.
    private static let sleepHeadPose: [Double] = [
        0.911, 0.004, 0.413, -0.021,
        -0.004, 1.0, -0.001, 0.001,
        -0.413, -0.001, 0.911, -0.044,
        0, 0, 0, 1,
    ]

    private static var target: [Double] {
        SleepPosition.target
    }

    private static func reading(
        _ adjust: (inout [Double]) -> Void = { _ in },
        wasInPosition: Bool = false
    ) -> SleepPosition.Reading {
        var actual = target
        adjust(&actual)
        return SleepPosition.reading(
            headJoints: Array(actual[0 ..< 7]),
            antennas: Array(actual[7 ..< 9]),
            wasInPosition: wasInPosition
        )
    }

    /// The targets are a cache of a solve, not numbers taken on trust: the cranks
    /// that hold the daemon's own sleep matrix, through this client's `StewartIK`.
    /// The matrix is printed to three decimals, so the solve agrees to a few
    /// thousandths of a radian — a tenth of a degree, against tolerances of twenty.
    @Test("the neck targets are the cranks that hold the daemon's sleep pose")
    func targetsComeFromTheSleepPose() throws {
        let pose = try #require(RigidTransform.matrix(rowMajor: Self.sleepHeadPose))
        let solved = try #require(StewartIK(geometry: RobotDescriptionFixture.geometry())
            .solve(headPose: pose, bodyYaw: 0))

        for (index, angle) in solved.enumerated() {
            #expect(abs(angle - Self.target[index + 1]) < 0.005, "stewart_\(index + 1): \(angle)")
        }
        #expect(Self.target[0] == 0)
    }

    @Test("a robot lying where goto_sleep left it is in position")
    func acceptsTheSleepPose() {
        #expect(Self.reading() == .inPosition)
    }

    /// A limp head sags, so the bands are wide: the question is wiring, not precision.
    @Test("a sagging head is still in position")
    func toleratesSag() {
        let reading = Self.reading { actual in
            for neck in 1 ... 6 {
                actual[neck] += 0.5
            }
            actual[0] -= 0.3
            actual[7] += 0.3
        }
        #expect(reading == .inPosition)
    }

    @Test("a motor beyond its band is named")
    func namesAMisplacedMotor() {
        let reading = Self.reading { $0[RobotMotor.neck3.rawValue] += 0.6 }
        #expect(reading == .outOfPosition(misplaced: [.neck3], swaps: []))
    }

    @Test("each motor kind has its own band", arguments: [
        (RobotMotor.base, 0.36), (.leftAntenna, 0.36), (.neck6, 0.56),
    ])
    func usesEachBand(_ motor: RobotMotor, _ offset: Double) {
        #expect(Self.reading { $0[motor.rawValue] += offset - 0.02 } == .inPosition)
        #expect(Self.reading { $0[motor.rawValue] += offset } == .outOfPosition(misplaced: [motor], swaps: []))
    }

    /// Without it a robot right at an edge flickers between the two answers, and the
    /// wake-up button with it.
    @Test("once in position, a motor has to go further to fall out")
    func holdsThePositionAtTheEdge() {
        let nudged: (inout [Double]) -> Void = { $0[RobotMotor.neck1.rawValue] += 0.6 }
        #expect(!Self.reading(nudged).isInPosition)
        #expect(Self.reading(nudged, wasInPosition: true).isInPosition)
        #expect(!Self.reading({ $0[RobotMotor.neck1.rawValue] += 0.7 }, wasInPosition: true).isInPosition)
    }

    /// Two cables in each other's sockets: each motor reports where the other one is.
    @Test("two motors reading each other's position are a swap")
    func findsASwap() {
        let reading = Self.reading { actual in
            actual.swapAt(RobotMotor.neck2.rawValue, RobotMotor.neck5.rawValue)
        }
        #expect(reading == .outOfPosition(misplaced: [.neck2, .neck5], swaps: [MotorSwap(.neck2, .neck5)]))
    }

    @Test("crossed antennas are a swap too")
    func findsCrossedAntennas() {
        let reading = Self.reading { $0.swapAt(RobotMotor.rightAntenna.rawValue, RobotMotor.leftAntenna.rawValue) }
        #expect(reading == .outOfPosition(
            misplaced: [.rightAntenna, .leftAntenna],
            swaps: [MotorSwap(.rightAntenna, .leftAntenna)]
        ))
    }

    /// Out of place is not the same as swapped: a head pushed sideways moves several
    /// motors without any of them landing on another's target.
    @Test("a misplaced motor is not called a swap without a partner")
    func doesNotInventASwap() {
        let reading = Self.reading { actual in
            actual[RobotMotor.neck2.rawValue] -= 1.2
            actual[RobotMotor.neck4.rawValue] += 0.9
        }
        #expect(reading == .outOfPosition(misplaced: [.neck2, .neck4], swaps: []))
    }

    /// A swap is both ways round. One motor sitting on another's target, with that
    /// other one somewhere else entirely, is a head pushed out of shape, not two cables
    /// in each other's sockets.
    @Test("one motor on another's target is not a swap by itself")
    func needsBothWaysRound() {
        let reading = Self.reading { actual in
            actual[RobotMotor.neck2.rawValue] = SleepPosition.target[RobotMotor.neck5.rawValue]
            actual[RobotMotor.neck5.rawValue] += 1.0
        }
        #expect(reading == .outOfPosition(misplaced: [.neck2, .neck5], swaps: []))
    }

    /// A daemon before 1.10.0 sends no motor-by-motor pose; the check must say so
    /// rather than call the robot misplaced and hold the wake-up for ever.
    @Test("no per-motor pose is unavailable, never out of position", arguments: [
        ([Double]?.none, [Double]?.some([-3.05, 3.05])),
        ([0, 0, 0, 0, 0, 0, 0], nil),
        ([0, 0, 0], [-3.05, 3.05]),
    ])
    func reportsNoData(_ headJoints: [Double]?, _ antennas: [Double]?) {
        #expect(SleepPosition.reading(headJoints: headJoints, antennas: antennas) == .unavailable)
    }
}
