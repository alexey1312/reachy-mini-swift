import Foundation
import simd

/// Head pose in, six motor angles out — the half of the kinematics the daemon has
/// always done for this client.
///
/// `PassiveJointSolver` next door is the opposite errand and says so in its own
/// first line: it is handed both the pose *and* the six angles and works out the
/// wrists that join them. Nothing here ever needed to produce the angles, because
/// a robot reports them in `head_joints`. A simulator has no robot to ask.
///
/// **Each leg solves on its own, in closed form.** A 6-RSS platform's crank swings
/// its rod's foot around a circle in the motor's own frame, so with the head pose
/// fixed the rod's other end is a known point and the whole leg reduces to one
/// scalar equation:
///
/// ```
/// |mount − tip(θ)| = rodLength
///   ⇒  mₓ cos θ + m_y sin θ = (|m|² + arm² − rod²) / 2·arm
/// ```
///
/// where `m` is the mount expressed in the motor frame. That is `A cos θ + B sin θ
/// = k`, whose roots are `atan2(B, A) ± acos(k / hypot(A, B))`. No iteration, no
/// seed, no convergence to check.
public struct StewartIK: Sendable {
    private let geometry: StewartGeometry

    public init(geometry: StewartGeometry) {
        self.geometry = geometry
    }

    /// The six motor angles that put the head where the pose says, or `nil` where
    /// no crank angle can reach it.
    ///
    /// - Parameters:
    ///   - headPose: as the daemon reports it — in the base frame, with the height
    ///     offset already taken out. `PassiveJointSolver.solve` takes the same
    ///     value and adds the offset back the same way, so a caller holding one
    ///     pose can feed both.
    ///   - bodyYaw: removed first. The daemon hands the platform `head_yaw −
    ///     body_yaw`, so a body turned without the head following is a platform
    ///     that has not moved — `(head 30°, body 30°)` really is neutral.
    ///
    /// `nil` is the workspace edge, where the two roots merge and beyond which the
    /// rod cannot reach. It is a real answer rather than a failure: the daemon
    /// clamps instead, and a caller that wants the daemon's behaviour clamps the
    /// pose before asking.
    public func solve(headPose: simd_double4x4, bodyYaw: Double) -> [Double]? {
        var pose = headPose
        pose.columns.3.z += geometry.headHeightOffset
        pose = RigidTransform.transform(
            rotation: RigidTransform.rotation(rpy: SIMD3(0, 0, -bodyYaw)),
            translation: .zero
        ) * pose

        var angles: [Double] = []
        angles.reserveCapacity(StewartGeometry.legCount)
        for leg in 0 ..< StewartGeometry.legCount {
            guard let angle = solveLeg(leg, pose: pose) else { return nil }
            angles.append(angle)
        }
        return angles
    }

    private func solveLeg(_ leg: Int, pose: simd_double4x4) -> Double? {
        let mount = Self.mount(leg, pose: pose, geometry: geometry)
        // In the motor's own frame the crank tip is (arm·cos θ, arm·sin θ, 0), which
        // is what collapses the leg to one equation in θ.
        let local = (geometry.motorFrames[leg].inverse * SIMD4(mount, 1)).xyz
        let radius = simd_length(SIMD2(local.x, local.y))
        guard radius > 1e-12 else { return nil }

        let arm = geometry.armLength
        let rod = geometry.rodLengths[leg]
        let target = (simd_length_squared(local) + arm * arm - rod * rod) / (2 * arm)
        let cosine = target / radius
        guard abs(cosine) <= 1 else { return nil }

        let phase = atan2(local.y, local.x)
        let offset = acos(cosine)
        // **The near root, and the margin is not close.** `phase` is ±91.7° on every
        // leg of the shipped description, so the two roots at rest are 0° and
        // ±183.4° apart — the far one folds the crank back through the robot and is
        // nowhere near any pose this platform reaches. Picking by distance from zero
        // keeps the solve stateless, which a seeded branch-follower would not.
        let roots = (phase - offset, phase + offset)
        return abs(roots.0) <= abs(roots.1) ? roots.0 : roots.1
    }

    /// Where this leg's rod meets the platform, carried by the pose.
    static func mount(_ leg: Int, pose: simd_double4x4, geometry: StewartGeometry) -> SIMD3<Double> {
        pose.rotation * geometry.branchPositions[leg] + pose.translation
    }

    /// The tip of the crank, swung by the motor angle. The same construction
    /// `PassiveJointSolver.solveLeg` makes, and the forward half this inverts.
    static func armTip(_ leg: Int, angle: Double, geometry: StewartGeometry) -> SIMD3<Double> {
        let crank = RigidTransform.rotation(rpy: SIMD3(0, 0, angle))
        let armInMotor = crank * SIMD3(geometry.armLength, 0, 0)
        return (geometry.motorFrames[leg] * SIMD4(armInMotor, 1)).xyz
    }
}
