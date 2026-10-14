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

    /// The pad's reach, and under the ~50° past which the daemon drops a pose silently
    /// (pollen-robotics/reachy_mini#1449).
    @Test("no axis goes past the pad's reach", arguments: [90.0, -90.0, 179.0])
    func clampsToTheHeadAngle(degrees: Double) {
        let angle = degrees * degree
        let aim = mapping.aim(HeadAttitude(yaw: angle, pitch: angle, roll: angle))
        for value in [aim.yaw, aim.pitch, aim.roll] {
            #expect(abs(value) == mapping.headAngle)
        }
        #expect(mapping.headAngle < 50 * degree)
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
