import Foundation
import os
import ReachyKit
import RealityKit
import simd

/// The robot as a RealityKit entity tree, with a fast path for re-posing it.
///
/// Built once from the URDF; after that only transforms change on the 20 Hz path,
/// which is what makes it cheap. Meshes are never rebuilt, and the one material
/// change there is — the shell's tint — happens when the theme changes, never per
/// frame.
@MainActor
public final class RobotSceneGraph {
    /// Carries the URDF's Z-up convention into RealityKit's Y-up world.
    public let root = Entity()

    private var linkEntities: [String: Entity] = [:]
    private var articulations: [Articulation] = []
    /// The shell's entities, each with the materials the description gave it, so
    /// painting back to `nil` restores rather than derives them a second time.
    private(set) var shellParts: [ShellPart] = []
    /// What the shell is painted now; `nil` is the description's own colours.
    public private(set) var shellTint: URDFColor?

    struct ShellPart {
        let entity: ModelEntity
        let original: [any Material]
    }

    /// One movable joint, with its fixed frame pre-split so posing is a single
    /// quaternion multiply.
    private struct Articulation {
        let entity: Entity
        let jointName: String
        let originTranslation: SIMD3<Float>
        let originRotation: simd_quatf
        let axis: SIMD3<Float>
    }

    /// The link the daemon's `head_pose` describes.
    private let headLinkName = "xl_330"
    private var baseEntity: Entity?
    /// Both halves of turning a `head_pose` into a transform for the drawn link —
    /// the rest height it is measured from, and the offset to the link the meshes
    /// hang off. Absent for a description with no Stewart platform in it, and the
    /// head is then left wherever the tree puts it.
    private let geometry: StewartGeometry?

    private nonisolated static let log = Logger(subsystem: "com.alexey1312.ReachyMini", category: "RobotSceneGraph")

    public init(urdf: URDFDocument, meshes: [String: MeshResource], geometry: StewartGeometry?) {
        self.geometry = geometry
        root.name = "robot"
        root.transform = Transform(rotation: simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))
        let base = buildLink(named: urdf.rootLinkName, urdf: urdf, meshes: meshes)
        baseEntity = base
        root.addChild(base)
        if shellParts.isEmpty {
            Self.log.debug("No shell meshes in this description; a theme will leave its colours alone")
        }
    }

    /// Paints the shell (`RobotShell`), or puts back the description's own colours
    /// for `nil`. Only the base colour changes — the material is otherwise the one
    /// every visual is built with. Idempotent, and a no-op for a description with no
    /// shell in it.
    public func applyShellTint(_ color: URDFColor?) {
        guard color != shellTint else { return }
        shellTint = color
        for part in shellParts {
            part.entity.model?.materials = color.map { [Self.material($0)] } ?? part.original
        }
    }

    /// Places the head straight from the daemon's pose.
    ///
    /// The head hangs off leg 6 through both passive wrists, so until those are
    /// solved the tree alone puts it in the wrong place. Driving it directly keeps
    /// the model readable in the meantime.
    public func applyHeadPose(_ pose: simd_double4x4?) {
        guard let pose,
              let head = linkEntities[headLinkName],
              let base = baseEntity,
              let geometry else { return }
        // Undoes the subtraction the daemon's `fk` ends with. Taken from the same
        // `StewartGeometry` the solver uses, because a lift that differs from the
        // solver's by even a little detaches the head from the rods pointing at it.
        var lifted = pose
        lifted.columns.3.z += geometry.headHeightOffset
        head.setTransformMatrix(simd_float4x4(lifted * geometry.headToDrawnLink), relativeTo: base)
    }

    public func entity(forLink name: String) -> Entity? {
        linkEntities[name]
    }

    /// What the camera should frame. Measured from the meshes rather than assumed,
    /// so it stays right whatever the robot's dimensions turn out to be.
    public var visualBounds: BoundingBox {
        root.visualBounds(relativeTo: nil)
    }

    public var movableJointNames: [String] {
        articulations.map(\.jointName)
    }

    /// Applies a pose. Joints the state does not mention keep their current angle,
    /// so a partial frame never snaps the robot to zero.
    public func apply(_ state: RobotJointState) {
        for articulation in articulations {
            guard let angle = state[articulation.jointName] else { continue }
            articulation.entity.transform = Transform(
                scale: .one,
                rotation: articulation.originRotation
                    * simd_quatf(angle: Float(angle), axis: articulation.axis),
                translation: articulation.originTranslation
            )
        }
    }

    private func buildLink(
        named name: String,
        urdf: URDFDocument,
        meshes: [String: MeshResource]
    ) -> Entity {
        let entity = Entity()
        entity.name = name
        linkEntities[name] = entity

        if let link = urdf.link(named: name) {
            for visual in link.visuals {
                if let model = makeVisual(visual, meshes: meshes) {
                    entity.addChild(model)
                }
            }
        }

        for joint in urdf.childJoints(of: name) {
            let child = buildLink(named: joint.child, urdf: urdf, meshes: meshes)
            attach(child, with: joint)
            entity.addChild(child)
        }
        return entity
    }

    private func attach(_ child: Entity, with joint: URDFJoint) {
        let origin = Transform(matrix: simd_float4x4(joint.origin.matrix))
        child.transform = origin
        guard joint.kind.isMovable else { return }
        articulations.append(Articulation(
            entity: child,
            jointName: joint.name,
            originTranslation: origin.translation,
            originRotation: origin.rotation,
            axis: SIMD3<Float>(joint.axis)
        ))
    }

    private func makeVisual(
        _ visual: URDFVisual,
        meshes: [String: MeshResource]
    ) -> ModelEntity? {
        guard case let .mesh(filename, _) = visual.geometry,
              let mesh = meshes[filename] else { return nil }
        let material = Self.material(visual.color ?? .unspecifiedVisual)
        let model = ModelEntity(mesh: mesh, materials: [material])
        model.transform = Transform(matrix: simd_float4x4(visual.origin.matrix))
        if RobotShell.contains(meshFilename: filename) {
            shellParts.append(ShellPart(entity: model, original: [material]))
        }
        return model
    }

    /// The one recipe for a visual's material, shared by the build and the tint so
    /// a painted shell differs from a factory one in colour and nothing else.
    private static func material(_ color: URDFColor) -> SimpleMaterial {
        SimpleMaterial(
            color: .init(
                red: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.alpha)
            ),
            roughness: 0.45,
            isMetallic: false
        )
    }
}

private extension simd_float4x4 {
    init(_ matrix: simd_double4x4) {
        self.init(
            SIMD4<Float>(matrix.columns.0),
            SIMD4<Float>(matrix.columns.1),
            SIMD4<Float>(matrix.columns.2),
            SIMD4<Float>(matrix.columns.3)
        )
    }
}
