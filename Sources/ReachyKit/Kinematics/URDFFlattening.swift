import Foundation
import simd

/// One `<visual>` lifted out of the link tree and expressed in the root link's
/// frame, with every joint at zero.
///
/// This is the shape a file format wants — USDZ, and anything else that has no
/// notion of a joint — where `URDFDocument` keeps the tree the robot is actually
/// articulated through. Nothing here articulates: the transform is the rest
/// configuration and only that.
public struct URDFVisualPlacement: Sendable, Equatable {
    /// The link this visual hangs off, kept so a reader can find it in the
    /// description again.
    public let link: String
    /// The bare filename, `package://` already stripped by `URDFParser` — the same
    /// key `RobotGeometryProvider` downloads under and `MeshResourceFactory` builds
    /// under.
    public let mesh: String
    /// The URDF's own, which is `(1, 1, 1)` throughout this robot's description.
    /// Carried rather than dropped because a description that did scale a mesh
    /// would otherwise be exported at the wrong size with nothing to say so.
    public let scale: SIMD3<Double>
    /// Resolved here rather than left optional, through the same default
    /// `RobotSceneGraph` draws an uncoloured visual with — one answer to "what
    /// colour is this", so an export and the on-screen twin cannot disagree.
    public let color: URDFColor
    /// Root link's frame → this visual's, at the zero configuration.
    public let transform: simd_double4x4

    public init(
        link: String,
        mesh: String,
        scale: SIMD3<Double>,
        color: URDFColor,
        transform: simd_double4x4
    ) {
        self.link = link
        self.mesh = mesh
        self.scale = scale
        self.color = color
        self.transform = transform
    }
}

public extension URDFDocument {
    /// Every link at or below the joint's child, the child itself included.
    ///
    /// Answers the empty set for a joint this description does not have, which is
    /// the useful answer for a caller naming an actuator by hand: a description
    /// without antennas has no antennas to leave out.
    func linksBelow(jointNamed name: String) -> Set<String> {
        guard let joint = joint(named: name) else { return [] }
        var found: Set<String> = []
        var pending = [joint.child]
        while let link = pending.popLast() {
            guard found.insert(link).inserted else { continue }
            pending.append(contentsOf: childJoints(of: link).map(\.child))
        }
        return found
    }

    /// Every mesh `<visual>` in the description, placed in the root link's frame.
    ///
    /// Composition is `restTransformFromRoot(link) * visual.origin`, which is the
    /// same pair `RobotSceneGraph` applies — the joint chain through the entity
    /// tree, then the visual's own offset on the `ModelEntity` under the link. The
    /// two agreeing is what lets a file exported from here be trained against and
    /// then anchored to, with the twin drawn in the frame the anchor establishes;
    /// `URDFFlatteningTests` holds that pair rather than trusting it.
    ///
    /// `excluding` drops whole links, which is how the exporter leaves the antennas
    /// out — see `linksBelow(jointNamed:)`. It is a set of links rather than of
    /// meshes because a mesh is shared: `antenna.stl` is drawn by the two antenna
    /// links and nothing else, but nothing in the format guarantees that.
    ///
    /// Links are walked in declaration order, and a link whose chain does not
    /// reach the root is skipped — `URDFDocument.init` already refuses a document
    /// with more than one root, so that cannot happen for a parsed description and
    /// is not worth an error case.
    func flattenedVisuals(excluding excludedLinks: Set<String> = []) -> [URDFVisualPlacement] {
        links.flatMap { link -> [URDFVisualPlacement] in
            guard !excludedLinks.contains(link.name),
                  let fromRoot = restTransformFromRoot(link.name) else { return [] }
            return link.visuals.compactMap { visual in
                guard case let .mesh(filename, scale) = visual.geometry else { return nil }
                return URDFVisualPlacement(
                    link: link.name,
                    mesh: filename,
                    scale: scale,
                    color: visual.color ?? .unspecifiedVisual,
                    transform: fromRoot * visual.origin.matrix
                )
            }
        }
    }
}
