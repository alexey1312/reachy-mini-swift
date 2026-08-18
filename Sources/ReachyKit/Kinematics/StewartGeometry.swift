import Foundation
import simd

/// Dimensions of the head's 6-RSS Stewart platform, read out of the robot's own
/// description.
///
/// Every value here also exists as a literal in upstream's kinematics data, but
/// deriving them keeps the client honest: a robot whose geometry differs — a new
/// hardware revision, a different shell — is drawn from its own numbers rather
/// than from ours. `StewartGeometryTests` pins the derivation against the known
/// dimensions so a change in either would be caught.
public struct StewartGeometry: Sendable {
    /// Six motor frames in the base link's frame, each already carrying the crank's
    /// vertical rise so the arm is a plain `[armLength, 0, 0]` in motor space.
    public let motorFrames: [simd_double4x4]
    /// Where each rod meets the platform, in the frame the daemon's head pose uses.
    public let branchPositions: [SIMD3<Double>]
    /// `rpy` of every `passive_i_x` joint: the rest orientation of each spherical
    /// wrist, seven in all.
    public let passiveOffsets: [SIMD3<Double>]
    /// Direction each rod points in its own wrist frame. Not axis-aligned for
    /// every leg — leg 2's mount is rotated.
    public let rodDirections: [SIMD3<Double>]
    public let armLength: Double
    /// How far each crank may actually turn, read off the `stewart_i` joints.
    ///
    /// **Skewed, and the skew is the mechanism rather than an artefact**:
    /// `stewart_1` reaches +80° but only −48°, `stewart_2` the mirror image, which
    /// is what lets the platform idle at the ±35.9° `head_pose` zero puts it at.
    /// A solve that lands outside one of these is a pose the robot cannot hold —
    /// `StewartIK.canHold(headPose:bodyYaw:)` is the question, and the answer is
    /// not the same as the rods' own reach: straight up, the solve answers to
    /// 24.3 mm of lift and the cranks run out of travel at 23.1.
    public let motorLimits: [ClosedRange<Double>]
    /// Rod length per leg, derived at the configuration where the linkage is
    /// actually **assembled** — every joint at zero, the head at its URDF rest
    /// height. There the five closing pairs meet to within a micrometre, which is
    /// what says the loop is closed; the six lengths come out at 0.085 m and agree
    /// to 5·10⁻⁷.
    ///
    /// **Not derived at `head_pose` zero, and the difference is 24 mm of stretched
    /// rod.** The daemon reports the head with `head_z_offset` already subtracted,
    /// and that offset is 27 mm *above* the rest height — so identity on the wire
    /// is the platform jacked up, not the robot at rest. Measuring there yields
    /// 0.109 m, a rod no leg of this robot has, and a solver built on it draws a
    /// robot sitting 27 mm too high while looking entirely plausible.
    public let rodLengths: [Double]
    /// The head's height with every joint at zero, in the root link's frame.
    /// 0.14957 on the shipped description.
    public let headRestHeight: Double
    /// What the daemon subtracted from the head's height before reporting it, so
    /// adding it back is how a `head_pose` becomes a position in the root link's
    /// frame. Every consumer — the solver and the scene graph both — has to use
    /// this one value, or the rods end up pointing at a head drawn somewhere else.
    ///
    /// The one number here that is *not* derived, because it is not a dimension of
    /// the robot: `head_z_offset` is a literal in the daemon's own kinematics
    /// (`placo_kinematics.py`, mirrored into `kinematics_data.json`), and both
    /// engines end `fk` with `T_world_head.z -= head_z_offset`. It is a reporting
    /// datum, and deriving a prettier number from the URDF only moves the drawn
    /// robot away from what the daemon said. Notably it is *not* the head's rest
    /// height: the URDF's zero configuration sits 27 mm lower, at 0.14957.
    public let headHeightOffset = Self.headZOffset

    /// The same number, reachable before `self` is whole — `init` needs it to place
    /// the rest pose the rod lengths are measured at.
    private static let headZOffset = 0.177
    /// Rest transform from the pose's frame to the link the meshes hang off.
    public let headToDrawnLink: simd_double4x4

    public static let legCount = 6
    public static let passiveChainCount = 7

    /// The wire value of the URDF's zero configuration — where `rodLengths` is
    /// measured — which is −0.02743 rather than zero.
    ///
    /// **Not the pose a robot idles at, and the difference is the point.** The
    /// client's neutral is `TeleopTarget()`, all zeros, and `gotoNeutral` sends
    /// `z: 0`; the daemon solves that at 27 mm higher than the modelled zero, which
    /// puts the six cranks at ±35.9°. That is not an artefact — the URDF's own
    /// limits are skewed the same way, `stewart_1` reaching +80° but only −48° and
    /// `stewart_2` the mirror image, so the mechanism is built to sit there. This
    /// value is a modelling datum for deriving rod lengths, nothing more.
    public var restHeadPoseZ: Double {
        headRestHeight - headHeightOffset
    }

    public init?(urdf: URDFDocument) {
        var motorFrames: [simd_double4x4] = []
        var rodDirections: [SIMD3<Double>] = []
        var branchPositions: [SIMD3<Double>] = []
        var passiveOffsets: [SIMD3<Double>] = []
        var motorLimits: [ClosedRange<Double>] = []
        var armLength: Double?

        for leg in 1 ... Self.legCount {
            guard let motor = urdf.joint(named: "stewart_\(leg)"),
                  let wrist = urdf.joint(named: "passive_\(leg)_x"),
                  let horn = urdf.restTransformFromRoot(motor.child),
                  let rod = Self.rodDirection(urdf: urdf, leg: leg),
                  let branch = Self.branchPosition(urdf: urdf, leg: leg) else { return nil }

            let crankRise = RigidTransform.transform(
                translation: SIMD3(0, 0, wrist.origin.xyz.z),
                rpy: .zero
            )
            motorFrames.append(horn * crankRise)
            rodDirections.append(rod)
            branchPositions.append(branch)
            // A revolute joint always carries one; the fallback is a full turn, so a
            // description that omitted it constrains nothing rather than everything.
            motorLimits.append(motor.limit ?? (-.pi ... .pi))
            armLength = armLength ?? simd_length(SIMD2(wrist.origin.xyz.x, wrist.origin.xyz.y))
        }

        for chain in 1 ... Self.passiveChainCount {
            guard let joint = urdf.joint(named: "passive_\(chain)_x") else { return nil }
            passiveOffsets.append(joint.origin.rpy)
        }

        guard let armLength,
              let headToDrawnLink = urdf.restTransform(from: "head", to: "xl_330"),
              let headRestHeight = urdf.restTransformFromRoot("head")?.translation.z else { return nil }

        // At the assembled configuration the crank is at zero, so each rod simply
        // spans from the tip of its arm to its mount on the platform.
        let restPose = RigidTransform.transform(
            rotation: matrix_identity_double3x3,
            translation: SIMD3(0, 0, headRestHeight)
        )
        rodLengths = (0 ..< Self.legCount).map { leg in
            let mount = restPose.rotation * branchPositions[leg] + restPose.translation
            let tip = (motorFrames[leg] * SIMD4(SIMD3(armLength, 0, 0), 1)).xyz
            return simd_length(mount - tip)
        }
        self.headRestHeight = headRestHeight
        self.motorFrames = motorFrames
        self.branchPositions = branchPositions
        self.passiveOffsets = passiveOffsets
        self.rodDirections = rodDirections
        self.armLength = armLength
        self.motorLimits = motorLimits
        self.headToDrawnLink = headToDrawnLink
    }

    /// Legs 1-5 end at a `closing_i_1` frame that closes the loop; leg 6 runs on
    /// through the seventh wrist to the head, so its rod is measured from there.
    private static func rodDirection(urdf: URDFDocument, leg: Int) -> SIMD3<Double>? {
        let joint = leg < legCount
            ? urdf.joints.first { $0.child == "closing_\(leg)_1" }
            : urdf.joint(named: "passive_\(passiveChainCount)_x")
        guard let offset = joint?.origin.xyz, simd_length(offset) > 0 else { return nil }
        return simd_normalize(offset)
    }

    /// Same asymmetry on the platform side: five closing frames, and the sixth
    /// point is the seventh wrist itself.
    private static func branchPosition(urdf: URDFDocument, leg: Int) -> SIMD3<Double>? {
        let target = leg < legCount ? "closing_\(leg)_2" : "passive_\(passiveChainCount)_link_x"
        return urdf.restTransform(from: "head", to: target)?.translation
    }
}
