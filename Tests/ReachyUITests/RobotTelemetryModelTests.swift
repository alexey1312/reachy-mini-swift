import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The "Share anonymous usage data" switch. Each guard here goes red when the
/// matching line in `RobotTelemetryModel` is removed (checked by mutating it).
@MainActor
@Suite("Robot telemetry switch")
struct RobotTelemetryModelTests {
    private static let shared = RobotTelemetry(isEnabled: true, isDisabledByEnvironment: false)
    private static let held = RobotTelemetry(isEnabled: true, isDisabledByEnvironment: true)

    /// Records every write, and answers it or throws.
    private final class Robot {
        var writes: [Bool] = []
        var refuses = false
        var reads = 0
    }

    private func model(
        _ robot: Robot,
        reads status: RobotTelemetry? = shared,
        readFails: Bool = false
    ) -> RobotTelemetryModel {
        RobotTelemetryModel(
            read: { _ in
                robot.reads += 1
                if readFails {
                    throw URLError(.timedOut)
                }
                return status
            },
            write: { _, isOn in
                robot.writes.append(isOn)
                if robot.refuses {
                    throw ReachyKitError.daemonRefused(statusCode: 500, detail: "Could not save setting")
                }
                return RobotTelemetry(isEnabled: isOn, isDisabledByEnvironment: false)
            }
        )
    }

    @Test("a read fills the switch, once per screen")
    func readsOnce() async {
        let robot = Robot()
        let model = model(robot)

        await model.load(session: .preview())
        await model.load(session: .preview())

        #expect(model.status == Self.shared)
        #expect(robot.reads == 1)
    }

    /// No answer, no switch: a guess would be a wrong statement about the robot.
    @Test("a failed read draws nothing, and is tried again next time")
    func failedReadDrawsNothing() async {
        let robot = Robot()
        let model = model(robot, readFails: true)

        await model.load(session: .preview())
        await model.load(session: .preview())

        #expect(model.status == nil)
        #expect(robot.reads == 2)
    }

    @Test("a write stores what the robot answered")
    func writes() async {
        let robot = Robot()
        let model = model(robot)
        await model.load(session: .preview())

        await model.setSharing(false, session: .preview())

        #expect(robot.writes == [false])
        #expect(model.status?.isEnabled == false)
        #expect(model.lastError == nil)
    }

    /// A refused write must not look like a saved one.
    @Test("a refused write puts the switch back and says why")
    func refusedWriteReverts() async {
        let robot = Robot()
        robot.refuses = true
        let model = model(robot)
        await model.load(session: .preview())

        await model.setSharing(false, session: .preview())

        #expect(model.status == Self.shared)
        #expect(model.lastError?.contains("Could not save setting") == true)
    }

    /// A variable on the robot holds it off: nothing the switch says would change
    /// what the robot does.
    @Test("a switch the robot holds off sends nothing")
    func heldOffSendsNothing() async {
        let robot = Robot()
        let model = model(robot, reads: Self.held)
        await model.load(session: .preview())

        await model.setSharing(false, session: .preview())

        #expect(robot.writes.isEmpty)
    }

    @Test("the same choice twice is one write")
    func sameChoiceIsNoWrite() async {
        let robot = Robot()
        let model = model(robot)
        await model.load(session: .preview())

        await model.setSharing(true, session: .preview())

        #expect(robot.writes.isEmpty)
    }
}
