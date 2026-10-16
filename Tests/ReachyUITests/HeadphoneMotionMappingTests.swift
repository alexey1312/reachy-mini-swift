import Foundation
@testable import ReachyUI
import Testing

/// What a head's attitude becomes on the robot. The signs themselves are a device
/// check (`HeadphoneMotionMapping`'s doc comment); what is pinned here is that each
/// axis goes where the mapping says, inside the pad's reach and outside the deadzone.
@Suite("Headphone motion mapping")
struct HeadphoneMotionMappingTests {
    private let mapping = HeadphoneMotionMapping()
    private let degree = Double.pi / 180

    @Test("a level head is a robot looking straight ahead")
    func levelIsNeutral() {
        #expect(mapping.aim(.level) == .zero)
    }

    @Test("a head held still inside the deadzone does not move the robot")
    func deadzoneHoldsStill() {
        let tremble = mapping.deadzone * 0.9
        #expect(mapping.aim(HeadAttitude(yaw: tremble, pitch: -tremble, roll: tremble)) == .zero)
    }

    /// Subtracted, not a threshold: the robot starts from zero at the deadzone's edge
    /// instead of jumping by its width.
    @Test("past the deadzone the robot moves by the excess only")
    func deadzoneIsSubtracted() {
        let aim = mapping.aim(HeadAttitude(yaw: mapping.deadzone + 10 * degree))
        #expect(abs(aim.yaw - 10 * degree) < 1e-12)
    }

    /// Alone, each axis stops at its own measured reach, and pitch is asymmetric: down
    /// is the motors' short side.
    @Test("an axis alone stops at its own reach", arguments: [90.0, -90.0])
    func eachAxisStopsAtItsReach(degrees: Double) {
        let angle = degrees * degree
        let yaw = mapping.aim(HeadAttitude(yaw: angle)).yaw
        let pitch = mapping.aim(HeadAttitude(pitch: angle)).pitch
        let roll = mapping.aim(HeadAttitude(roll: angle)).roll
        #expect(abs(yaw) == mapping.yawReach)
        #expect(abs(roll) == mapping.rollReach)
        #expect(pitch == (pitch > 0 ? mapping.pitchDownReach : -mapping.pitchUpReach))
        #expect(mapping.pitchDownReach != mapping.pitchUpReach)
    }

    /// Per-axis limits alone let 30° up and 30° of roll through together, and the
    /// daemon's IK puts a motor past its URDF limit there. The cone is what stops it.
    @Test("pitch and roll together stay inside the tilt cone, leaning the same way")
    func tiltStaysInsideTheCone() {
        let lean = 60 * degree
        // Core Motion's negative pitch is the robot's positive one, looking down.
        let aim = mapping.aim(HeadAttitude(pitch: -lean, roll: lean))
        let tilt = (aim.pitch * aim.pitch + aim.roll * aim.roll).squareRoot()
        #expect(abs(tilt - mapping.tiltReach) < 1e-12)
        #expect(aim.pitch > 0)
        // Each axis was clamped to its own reach, then both were scaled by one factor.
        #expect(abs(aim.pitch / aim.roll - mapping.pitchDownReach / mapping.rollReach) < 1e-12)
    }

    @Test("a tilt inside the cone passes through unscaled")
    func smallTiltIsUntouched() {
        let lean = 10 * degree + mapping.deadzone
        let aim = mapping.aim(HeadAttitude(pitch: lean, roll: lean))
        #expect(abs(abs(aim.pitch) - 10 * degree) < 1e-12)
        #expect(abs(aim.roll - 10 * degree) < 1e-12)
    }

    /// Every reach stays under the ~50° past which the daemon drops a pose silently
    /// (pollen-robotics/reachy_mini#1449).
    @Test("every reach stays under the daemon's silent cut-off")
    func reachesStayUnderTheCutOff() {
        let reaches = [mapping.yawReach, mapping.pitchDownReach, mapping.pitchUpReach, mapping.rollReach]
        #expect(reaches.allSatisfy { $0 < 50 * degree })
        #expect(mapping.tiltReach < 50 * degree)
    }

    /// Each sign is one number to flip after the device check, and this is what keeps
    /// each one acting on its own axis.
    @Test("each axis follows its own sign")
    func signsActPerAxis() {
        let turn = 20 * degree
        let aim = mapping.aim(HeadAttitude(yaw: turn, pitch: turn, roll: turn))
        #expect((aim.yaw > 0) == (mapping.yawSign > 0))
        #expect((aim.pitch > 0) == (mapping.pitchSign > 0))
        #expect((aim.roll > 0) == (mapping.rollSign > 0))

        var flipped = mapping
        flipped.pitchSign = -mapping.pitchSign
        #expect(flipped.aim(HeadAttitude(pitch: turn)).pitch == -aim.pitch)
        #expect(flipped.aim(HeadAttitude(yaw: turn)).yaw == aim.yaw)
    }
}
