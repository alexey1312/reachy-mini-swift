import Foundation
@testable import ReachyKit
import simd
import Testing

/// A 6-RSS description with the awkward parts kept: wrists that rest at a real
/// orientation and a rod that is not axis-aligned in its own frame. Both are true
/// of the robot, and both are what make the order of a wrist's three angles
/// matter — a fixture of right angles and zero offsets would pass either way.
private enum WristFixture {
    static let armLength = 0.04
    static let crankRise = 0.007
    static let crankCircle = 0.038
    static let rodLength = 0.085

    /// `rpy` of the seven `passive_i_x` joints, in the shape the robot's own
    /// description writes them: nowhere near zero, and different per leg.
    static let wristOffsets: [SIMD3<Double>] = [
        SIMD3(-0.14, -0.09, 2.10),
        SIMD3(-3.14, 0.00, -3.14),
        SIMD3(0.37, 0.09, -1.04),
        SIMD3(-0.09, 0.09, 1.04),
        SIMD3(0.12, 0.09, -1.04),
        SIMD3(3.06, 0.09, 1.04),
        SIMD3(3.14, 0.00, 0.00),
    ]

    /// Deliberately off-axis, so the rotation each wrist has to take is a general
    /// one rather than a turn about a single joint.
    static let rodDirection = simd_normalize(SIMD3<Double>(0.98, 0, 0.2))

    private static let legAngles = [46.5, 73.5, 166.5, -166.5, -73.5, -46.5]
        .map { $0 * .pi / 180 }

    static func document() throws -> URDFDocument {
        var links = [
            URDFLink(name: "base", visuals: []),
            URDFLink(name: "passive_7_link_x", visuals: []),
            URDFLink(name: "xl_330", visuals: []),
            URDFLink(name: "head", visuals: []),
        ]
        var joints: [URDFJoint] = []

        for leg in 1 ... StewartGeometry.legCount {
            let angle = legAngles[leg - 1]
            links.append(URDFLink(name: "horn_\(leg)", visuals: []))
            links.append(URDFLink(name: "passive_\(leg)_link_x", visuals: []))
            joints.append(URDFJoint(
                name: "stewart_\(leg)", kind: .revolute, parent: "base", child: "horn_\(leg)",
                origin: URDFPose(
                    xyz: SIMD3(crankCircle * cos(angle), crankCircle * sin(angle), 0.042),
                    rpy: SIMD3(Double.pi / 2, 0, angle)
                ),
                axis: SIMD3(0, 0, 1), limit: nil
            ))
            joints.append(fixed(
                "passive_\(leg)_x", from: "horn_\(leg)", to: "passive_\(leg)_link_x",
                xyz: SIMD3(armLength, 0, crankRise), rpy: wristOffsets[leg - 1]
            ))
            guard leg < StewartGeometry.legCount else { continue }
            // Legs 1-5 close the loop through a pair of frames; leg 6 runs on to the head.
            links.append(URDFLink(name: "closing_\(leg)_1", visuals: []))
            links.append(URDFLink(name: "closing_\(leg)_2", visuals: []))
            joints.append(fixed(
                "rod_\(leg)", from: "passive_\(leg)_link_x", to: "closing_\(leg)_1",
                xyz: rodDirection * rodLength
            ))
            joints.append(fixed(
                "close_\(leg)", from: "head", to: "closing_\(leg)_2",
                xyz: SIMD3(0.03 * cos(angle), 0.03 * sin(angle), 0)
            ))
        }

        joints.append(fixed(
            "passive_7_x", from: "passive_6_link_x", to: "passive_7_link_x",
            xyz: rodDirection * rodLength, rpy: wristOffsets[6]
        ))
        joints.append(fixed("neck", from: "passive_7_link_x", to: "xl_330", xyz: SIMD3(0, 0, 0.01)))
        joints.append(fixed("head_frame", from: "xl_330", to: "head", xyz: SIMD3(0, 0, 0.02)))

        return try URDFDocument(name: "wrist-fixture", links: links, joints: joints)
    }

    private static func fixed(
        _ name: String,
        from: String,
        to: String,
        xyz: SIMD3<Double>,
        rpy: SIMD3<Double> = .zero
    ) -> URDFJoint {
        URDFJoint(
            name: name, kind: .fixed, parent: from, child: to,
            origin: URDFPose(xyz: xyz, rpy: rpy), axis: SIMD3(1, 0, 0), limit: nil
        )
    }
}

/// The solver hands each wrist three numbers for three stacked revolute joints, so
/// the only assertion that means anything is that **the joint chain** rebuilds the
/// direction they were extracted from.
///
/// `PassiveJointSolverTests` asks the same question of a real description and is
/// gated on one being present; this runs everywhere, because the convention it
/// pins is the whole reason the drawn rods once pointed centimetres past the head
/// they hold.
@Suite("Passive wrist angles rebuild their joint chain")
struct PassiveJointChainTests {
    /// `passive_i_x` → `_y` → `_z`, each about its own axis — built from the axis
    /// primitive rather than from `wristRotation`, so the solver and the check
    /// cannot share a mistake.
    private func chain(_ angles: SIMD3<Double>) -> simd_double3x3 {
        RigidTransform.rotation(axis: SIMD3(1, 0, 0), angle: angles.x)
            * RigidTransform.rotation(axis: SIMD3(0, 1, 0), angle: angles.y)
            * RigidTransform.rotation(axis: SIMD3(0, 0, 1), angle: angles.z)
    }

    @Test("every rod points where the solver said it would")
    func rodsPointWhereSolved() throws {
        let urdf = try WristFixture.document()
        let geometry = try #require(StewartGeometry(urdf: urdf))
        let solver = PassiveJointSolver(geometry: geometry)

        let stewart = [0.22, -0.18, 0.31, -0.27, 0.14, -0.35]
        let bodyYaw = 0.4
        var pose = RigidTransform.transform(
            translation: SIMD3(0.006, -0.004, 0.012),
            rpy: SIMD3(0.18, -0.22, 0.1)
        )
        let angles = solver.solve(headPose: pose, bodyYaw: bodyYaw, stewart: stewart)
        #expect(angles.count == 21)

        // Rebuild the solver's own frame so the comparison is like for like.
        pose.columns.3.z += geometry.headHeightOffset
        pose = RigidTransform.transform(
            rotation: RigidTransform.rotation(rpy: SIMD3(0, 0, -bodyYaw)),
            translation: .zero
        ) * pose

        var widest = 0.0
        for leg in 0 ..< StewartGeometry.legCount {
            let motor = geometry.motorFrames[leg]
            let crank = RigidTransform.rotation(rpy: SIMD3(0, 0, stewart[leg]))
            let mount = pose.rotation * geometry.branchPositions[leg] + pose.translation
            let tip = (motor * SIMD4(crank * SIMD3(geometry.armLength, 0, 0), 1)).xyz
            let wrist = motor.rotation * crank
                * RigidTransform.rotation(rpy: geometry.passiveOffsets[leg])

            let wanted = simd_normalize(wrist.transpose * (mount - tip))
            let solved = SIMD3(angles[leg * 3], angles[leg * 3 + 1], angles[leg * 3 + 2])
            let pointing = chain(solved) * geometry.rodDirections[leg]
            #expect(simd_distance(pointing, wanted) < 1e-9, "leg \(leg + 1)")
            let dot = min(1.0, max(-1.0, simd_dot(geometry.rodDirections[leg], wanted)))
            widest = max(widest, acos(dot))
        }
        // A wrist barely off its rest orientation would agree under any convention,
        // so the fixture has to keep asking for a real rotation.
        let degrees = widest * 180 / Double.pi
        #expect(widest > 1, "the widest wrist only bends \(degrees)°")
    }
}
