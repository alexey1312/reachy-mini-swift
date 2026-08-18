import Foundation
@testable import ReachyKit
import simd
import Testing

/// Head pose in, six motor angles out — the half of the kinematics a robot has
/// always done for this client, and a simulator has to do for itself.
///
/// Every assertion runs against the real description (`RobotDescriptionFixture`),
/// because the platform's dimensions are the whole problem: a toy fixture would
/// only exercise the algebra.
@Suite("Stewart inverse kinematics")
struct StewartIKTests {
    /// A named pose to solve. A struct rather than a tuple because SwiftLint stops
    /// at two members, and a case here is three things.
    private struct Case {
        let label: String
        let headPose: simd_double4x4
        let bodyYaw: Double

        init(_ label: String, _ headPose: simd_double4x4, bodyYaw: Double = 0) {
            self.label = label
            self.headPose = headPose
            self.bodyYaw = bodyYaw
        }
    }

    private func solver() throws -> (StewartIK, StewartGeometry) {
        let geometry = try RobotDescriptionFixture.geometry()
        return (StewartIK(geometry: geometry), geometry)
    }

    private func pose(
        z: Double,
        roll: Double = 0,
        pitch: Double = 0,
        yaw: Double = 0,
        x: Double = 0
    ) -> simd_double4x4 {
        RigidTransform.transform(translation: SIMD3(x, 0, z), rpy: SIMD3(roll, pitch, yaw))
    }

    private func degrees(_ radians: [Double]) -> [Double] {
        radians.map { $0 * 180 / .pi }
    }

    // MARK: - What the rod length is measured at

    /// **The mistake this test exists to prevent, because it looks right.** Measure
    /// the rods at `head_pose` zero and they come out 0.109 m; measure them where
    /// the linkage is assembled and they are 0.085 m, the length upstream's own
    /// data and `PassiveJointChainTests`' fixture both carry. The 24 mm difference
    /// is the daemon's `head_z_offset` sitting 27 mm above the rest height, and a
    /// solver built on the wrong one draws a robot sitting 27 mm too high with
    /// stretched rods — entirely plausible, and wrong everywhere.
    @Test("rods are measured where the linkage is assembled, not at pose zero")
    func rodLengthsComeFromTheRestConfiguration() throws {
        let (_, geometry) = try solver()

        #expect(abs(geometry.headRestHeight - 0.149571) < 1e-5)
        #expect(abs(geometry.restHeadPoseZ - -0.027429) < 1e-5)
        for (leg, rod) in geometry.rodLengths.enumerated() {
            #expect(abs(rod - 0.085) < 1e-5, "leg \(leg + 1) rod \(rod)")
        }
    }

    // MARK: - The two facts the daemon's own kinematics were measured for

    @Test("a robot at its rest pose solves to six zero angles")
    func restPoseSolvesToZero() throws {
        let (ik, geometry) = try solver()

        let angles = try #require(ik.solve(headPose: pose(z: geometry.restHeadPoseZ), bodyYaw: 0))

        #expect(angles.count == 6)
        for (leg, angle) in angles.enumerated() {
            #expect(abs(angle) < 1e-9, "leg \(leg + 1) is \(angle)")
        }
    }

    /// `.claude/rules/daemon-api.md`: the daemon hands the platform
    /// `head_yaw − body_yaw`, measured against the shipped `reachy_mini_rust_kinematics`
    /// rather than read off any doc. Turning the body and the head together is a
    /// platform that has not moved.
    @Test("(head 30, body 30) is neutral, bit for bit")
    func bodyYawIsSubtracted() throws {
        let (ik, geometry) = try solver()
        let z = geometry.restHeadPoseZ

        let rest = try #require(ik.solve(headPose: pose(z: z), bodyYaw: 0))
        let turned = try #require(
            ik.solve(headPose: pose(z: z, yaw: .pi / 6), bodyYaw: .pi / 6)
        )

        for (leg, (a, b)) in zip(rest, turned).enumerated() {
            #expect(abs(a - b) < 1e-9, "leg \(leg + 1): \(a) vs \(b)")
        }
    }

    /// The same rule from the other side, and the other half of the recorded
    /// measurement: only the difference reaches the platform.
    @Test("(head 0, body 30) is (head -30, body 0)")
    func onlyTheDifferenceReachesThePlatform() throws {
        let (ik, geometry) = try solver()
        let z = geometry.restHeadPoseZ

        let bodyTurned = try #require(ik.solve(headPose: pose(z: z), bodyYaw: .pi / 6))
        let headTurned = try #require(ik.solve(headPose: pose(z: z, yaw: -.pi / 6), bodyYaw: 0))

        for (leg, (a, b)) in zip(bodyTurned, headTurned).enumerated() {
            #expect(abs(a - b) < 1e-9, "leg \(leg + 1): \(a) vs \(b)")
        }
    }

    // MARK: - The invariant that proves the solve rather than pinning its output

    /// Every assertion above compares one solve against another, so all of them
    /// would pass on a solver that is consistently wrong. This one does not: it
    /// rebuilds the leg from the angle that came out and checks the rod still has
    /// the length it has. Nothing but a correct solve satisfies it.
    @Test("every solved leg spans exactly its rod length")
    func solvedLegsSpanTheirRods() throws {
        let (ik, geometry) = try solver()
        let z = geometry.restHeadPoseZ
        let cases = [
            Case("rest", pose(z: z)),
            Case("pitch 15", pose(z: z, pitch: .pi / 12)),
            Case("roll -12", pose(z: z, roll: -12 * .pi / 180)),
            Case("yaw 65 — the relative-yaw clamp", pose(z: z, yaw: 65 * .pi / 180)),
            Case("body 30", pose(z: z), bodyYaw: .pi / 6),
            Case("up 10 mm", pose(z: z + 0.010)),
            Case("down 10 mm", pose(z: z - 0.010)),
            Case("forward 12 mm, pitch 10", pose(z: z, pitch: .pi / 18, x: 0.012)),
        ]

        for testCase in cases {
            let (label, headPose, bodyYaw) = (testCase.label, testCase.headPose, testCase.bodyYaw)
            let angles = try #require(ik.solve(headPose: headPose, bodyYaw: bodyYaw), "\(label) unreachable")
            // The frame the solve works in: the daemon reports the head with its
            // offset taken off, and hands the platform the yaw difference.
            var platform = headPose
            platform.columns.3.z += geometry.headHeightOffset
            platform = RigidTransform.transform(
                rotation: RigidTransform.rotation(rpy: SIMD3(0, 0, -bodyYaw)),
                translation: .zero
            ) * platform

            for leg in 0 ..< StewartGeometry.legCount {
                let span = simd_length(
                    StewartIK.mount(leg, pose: platform, geometry: geometry)
                        - StewartIK.armTip(leg, angle: angles[leg], geometry: geometry)
                )
                #expect(abs(span - geometry.rodLengths[leg]) < 1e-9, "\(label), leg \(leg + 1): span \(span)")
            }
        }
    }

    // MARK: - The edges

    /// Identity on the wire is **not** the robot at rest — it is the platform
    /// jacked up by the daemon's 27 mm offset, which every crank has to reach for.
    /// Worth pinning: a simulator that idles here rather than at `restHeadPoseZ`
    /// would sit visibly high and never look wrong enough to investigate.
    @Test("pose zero is the platform raised, not the robot at rest")
    func poseZeroIsNotTheRestPose() throws {
        let (ik, _) = try solver()

        let angles = try #require(ik.solve(headPose: pose(z: 0), bodyYaw: 0))

        for (leg, angle) in degrees(angles).enumerated() {
            #expect(abs(abs(angle) - 35.9) < 0.05, "leg \(leg + 1) is \(angle)°")
        }
    }

    /// Beyond the workspace the two roots merge and there is no crank angle at all.
    /// `nil` rather than a clamp: the daemon clamps the *pose* before solving, and a
    /// solver that quietly returned the nearest reachable thing would hide the
    /// difference from whoever has to make that choice.
    @Test("a pose no crank can reach is refused")
    func unreachablePoseIsRefused() throws {
        let (ik, geometry) = try solver()

        #expect(ik.solve(headPose: pose(z: geometry.restHeadPoseZ + 0.060), bodyYaw: 0) == nil)
    }
}
