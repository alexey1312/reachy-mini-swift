import Foundation
import simd

/// Works out the 21 passive joint angles of the head's Stewart platform.
///
/// The daemon reports them only under the Placo engine, and ships with the
/// analytical one, so a client that wants to draw the linkage has to fill the gap
/// itself. This is not inverse kinematics: the head pose and the six motor angles
/// are both known, and what remains is the orientation each rod must take to span
/// the gap between its crank tip and its mount on the platform. The loop is never
/// closed and the rod length never enforced — for a viewer, pointing each rod the
/// right way is enough, and any residual is far below a pixel.
///
/// Each wrist leaves here as three angles for three stacked revolute joints, so it
/// is decomposed with ``RigidTransform/wristAngles(from:)`` and never with the
/// URDF-`rpy` extraction beside it: the chain composes `Rx * Ry * Rz` and `rpy`
/// composes `Rz * Ry * Rx`. The two agree to first order, so the rest pose and a
/// small nod look right either way — but these wrists sit 80–110° from their rest
/// orientation across the head's whole working range, and there the wrong order
/// aimed the rods up to 8 cm past the head they hold.
public struct PassiveJointSolver: Sendable {
    private let geometry: StewartGeometry

    public init(geometry: StewartGeometry) {
        self.geometry = geometry
    }

    /// - Parameters:
    ///   - headPose: from the state stream, in the base frame.
    ///   - bodyYaw: removed first, so the rest of the work happens in the frame the
    ///     platform's constants are written in.
    ///   - stewart: the six motor angles.
    public func solve(
        headPose: simd_double4x4,
        bodyYaw: Double,
        stewart: [Double]
    ) -> [Double] {
        guard stewart.count >= StewartGeometry.legCount else {
            return Array(repeating: 0, count: StewartGeometry.passiveChainCount * 3)
        }
        var pose = headPose
        pose.columns.3.z += geometry.headHeightOffset
        pose = RigidTransform.transform(
            rotation: RigidTransform.rotation(rpy: SIMD3(0, 0, -bodyYaw)),
            translation: .zero
        ) * pose

        var angles: [Double] = []
        angles.reserveCapacity(StewartGeometry.passiveChainCount * 3)
        var lastWrist: (frame: simd_double3x3, rotation: simd_double3x3)?

        for leg in 0 ..< StewartGeometry.legCount {
            let solved = solveLeg(leg, pose: pose, angle: stewart[leg])
            angles.append(contentsOf: [solved.angles.x, solved.angles.y, solved.angles.z])
            lastWrist = (solved.wristFrame, solved.rodRotation)
        }

        angles.append(contentsOf: headWrist(pose: pose, lastWrist: lastWrist))
        return angles
    }

    private struct SolvedLeg {
        /// The wrist's three joint angles, in chain order.
        let angles: SIMD3<Double>
        let wristFrame: simd_double3x3
        let rodRotation: simd_double3x3
    }

    private func solveLeg(_ leg: Int, pose: simd_double4x4, angle: Double) -> SolvedLeg {
        let motor = geometry.motorFrames[leg]
        let crank = RigidTransform.rotation(rpy: SIMD3(0, 0, angle))

        // Where this rod has to reach: its mount on the platform, carried by the pose.
        let mount = pose.rotation * geometry.branchPositions[leg] + pose.translation
        // Where it starts: the tip of the crank, swung by the motor angle.
        let armInMotor = crank * SIMD3(geometry.armLength, 0, 0)
        let tip = (motor * SIMD4(armInMotor, 1)).xyz

        // The wrist sits on the crank, already turned to its rest orientation.
        let wristFrame = motor.rotation * crank
            * RigidTransform.rotation(rpy: geometry.passiveOffsets[leg])
        let span = mount - tip
        guard simd_length(span) > 1e-12 else {
            return SolvedLeg(
                angles: .zero,
                wristFrame: wristFrame,
                rodRotation: matrix_identity_double3x3
            )
        }
        let direction = simd_normalize(wristFrame.transpose * span)
        let rodRotation = RigidTransform.alignment(from: geometry.rodDirections[leg], to: direction)
        return SolvedLeg(
            angles: RigidTransform.wristAngles(from: rodRotation),
            wristFrame: wristFrame,
            rodRotation: rodRotation
        )
    }

    /// The seventh wrist joins leg 6's rod to the head, so its angles are whatever
    /// is left between the rod's orientation and the head's.
    private func headWrist(
        pose: simd_double4x4,
        lastWrist: (frame: simd_double3x3, rotation: simd_double3x3)?
    ) -> [Double] {
        guard let lastWrist else { return [0, 0, 0] }
        let head = pose.rotation * geometry.headToDrawnLink.rotation
        let rod = lastWrist.frame * lastWrist.rotation
            * RigidTransform.rotation(rpy: geometry.passiveOffsets[StewartGeometry.legCount])
        let angles = RigidTransform.wristAngles(from: rod.transpose * head)
        return [angles.x, angles.y, angles.z]
    }
}
