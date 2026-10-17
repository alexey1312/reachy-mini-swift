import Foundation
@testable import ReachyUI
import simd
import Testing

/// The headset's pose as a turn, a nod and a tilt, and what they become on the robot.
///
/// ARKit's frame is documented — right-handed, y up, the device looking along -z —
/// so unlike the headphones' these signs can be pinned without a device. Each pose
/// is built as a rotation about one world axis, and `forward(of:)` and `right(of:)`
/// say what that rotation does to the head before any angle is read from it, so a
/// test cannot pass by decomposing the way it composed.
@Suite("Headset attitude")
struct HeadsetAttitudeTests {
    private let degree = Double.pi / 180
    private let mapping = HeadphoneMotionMapping.headset

    private func rotation(_ angle: Double, about axis: SIMD3<Float>) -> simd_quatf {
        simd_quatf(angle: Float(angle * degree), axis: axis)
    }

    private func pose(_ rotation: simd_quatf, at position: SIMD3<Float> = .zero) -> simd_float4x4 {
        var transform = simd_float4x4(rotation)
        transform.columns.3 = SIMD4(position, 1)
        return transform
    }

    /// A head turned `yaw`, then nodded `pitch`, then tilted `roll`, in degrees.
    private func head(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) -> simd_float4x4 {
        pose(rotation(yaw, about: [0, 1, 0]) * rotation(pitch, about: [1, 0, 0]) * rotation(roll, about: [0, 0, 1]))
    }

    private func forward(of transform: simd_float4x4) -> SIMD3<Float> {
        -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
    }

    private func right(of transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
    }

    private func isClose(_ angle: Double, _ degrees: Double) -> Bool {
        abs(angle - degrees * degree) < 1e-5
    }

    @Test("a head turned left reads a positive yaw and turns the robot to its left")
    func turnLeft() {
        let turned = pose(rotation(20, about: [0, 1, 0]))
        #expect(forward(of: turned).x < 0)

        let attitude = HeadsetAttitude.angles(of: turned)

        #expect(isClose(attitude.yaw, 20))
        #expect(isClose(attitude.pitch, 0))
        #expect(isClose(attitude.roll, 0))
        #expect(mapping.aim(attitude).yaw > 0)
    }

    @Test("a head nodded down reads a negative pitch and tips the robot's head down")
    func nodDown() {
        let nodded = pose(rotation(-15, about: [1, 0, 0]))
        #expect(forward(of: nodded).y < 0)

        let attitude = HeadsetAttitude.angles(of: nodded)

        #expect(isClose(attitude.pitch, -15))
        #expect(isClose(attitude.yaw, 0))
        #expect(mapping.aim(attitude).pitch > 0)
    }

    /// The one sign the headset turns round from the headphones' default: ARKit's
    /// roll is positive with the left ear down, the robot's with the right.
    @Test("a head with its right ear down tilts the robot's right ear down")
    func rightEarDown() {
        let tilted = pose(rotation(-10, about: [0, 0, 1]))
        #expect(right(of: tilted).y < 0)

        let attitude = HeadsetAttitude.angles(of: tilted)

        #expect(isClose(attitude.roll, -10))
        #expect(mapping.aim(attitude).roll > 0)
    }

    @Test("a turn, a nod and a tilt together come back as the three angles")
    func composedComesBack() {
        let attitude = HeadsetAttitude.angles(of: head(yaw: 30, pitch: -12, roll: 8))

        #expect(isClose(attitude.yaw, 30))
        #expect(isClose(attitude.pitch, -12))
        #expect(isClose(attitude.roll, 8))
    }

    @Test("where the head is does not matter, only where it looks")
    func translationIsIgnored() {
        let here = HeadsetAttitude.angles(of: head(yaw: 25, pitch: 5))
        let there = HeadsetAttitude.angles(
            of: pose(rotation(25, about: [0, 1, 0]) * rotation(5, about: [1, 0, 0]), at: [0.4, 1.6, -2])
        )
        #expect(abs(here.yaw - there.yaw) < 1e-6)
        #expect(abs(here.pitch - there.pitch) < 1e-6)
    }

    @Test("a reading is measured from the reference's heading")
    func relativeToReference() {
        let attitude = HeadsetAttitude.attitude(of: head(yaw: 100), from: head(yaw: 90))
        #expect(isClose(attitude.yaw, 10))
    }

    /// Across the back, where ±180° meet, a 20° turn must stay 20° and not become 340°.
    @Test("a turn across ±180° is the short way round")
    func wrapsAcrossTheBack() {
        let attitude = HeadsetAttitude.attitude(of: head(yaw: -170), from: head(yaw: 170))
        #expect(isClose(attitude.yaw, 20))
    }

    /// The reason the angles are subtracted rather than the rotations composed: a
    /// reference taken looking a little down must not turn a turn into a tilt.
    @Test("from a reference looking down, a turn is a turn and nothing else")
    func turnStaysPureFromATiltedReference() {
        let attitude = HeadsetAttitude.attitude(of: head(yaw: 30, pitch: -10), from: head(pitch: -10))

        #expect(isClose(attitude.yaw, 30))
        #expect(isClose(attitude.pitch, 0))
        #expect(isClose(attitude.roll, 0))
    }

    @Test("the reference itself reads level")
    func referenceIsLevel() {
        let reference = head(yaw: 40, pitch: -8, roll: 3)
        #expect(mapping.aim(HeadsetAttitude.attitude(of: reference, from: reference)) == .zero)
    }

    /// The headset keeps the measured reach: the mapping changed one sign, not a limit.
    @Test("the headset keeps the headphones' measured reach")
    func keepsTheReach() {
        let headphones = HeadphoneMotionMapping()
        #expect(mapping.yawReach == headphones.yawReach)
        #expect(mapping.pitchDownReach == headphones.pitchDownReach)
        #expect(mapping.pitchUpReach == headphones.pitchUpReach)
        #expect(mapping.rollReach == headphones.rollReach)
        #expect(mapping.tiltReach == headphones.tiltReach)
        #expect(mapping.yawSign == headphones.yawSign)
        #expect(mapping.pitchSign == headphones.pitchSign)
        #expect(mapping.rollSign == -headphones.rollSign)
    }
}
