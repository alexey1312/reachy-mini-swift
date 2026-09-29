import Foundation
@testable import ReachyKit
@testable import ReachyScene
import ReachySimulator
import RealityKit
import simd
import Testing

/// `URDFDocument.flattenedVisuals()` exists so a mesh can be written into a file
/// format that has no notion of a joint — the USDZ an object tracker is trained
/// from. What makes that file usable as a *reference* is that it stands in the same
/// frame the twin is drawn in: anchor the twin to the object trained from the
/// export and the two coincide, or they do not and nothing on screen explains why.
///
/// So the property under test is not "the flattening is correct" in the abstract —
/// it is that the flattening and `RobotSceneGraph` place every one of the real
/// robot's 162 visuals in the same place, differing only by the root rotation the
/// graph applies to carry URDF's Z-up into RealityKit's Y-up. Nothing else in the
/// repository compares those two paths, and they are written independently: one
/// composes matrices, the other nests entities.
@MainActor
@Suite("URDF flattening against the scene graph")
struct URDFFlatteningTests {
    /// The one constant this suite repeats rather than reads, and the one the
    /// exporter has to bake. `RobotSceneGraph` applies it to `root`, so everything
    /// *under* root — which is every comparison below — is still in the URDF's
    /// Z-up frame, and the rotation is what carries that whole tree into
    /// RealityKit's world. A USDZ exported for training therefore has to carry the
    /// same rotation, or the anchor it produces stands the robot on its side.
    /// The first test holds this copy against the graph's.
    private static let zUpToYUp = simd_double4x4(
        simd_quatd(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
    )

    private static func document() throws -> URDFDocument {
        try URDFParser.parse(BundledRobotGeometry().urdf())
    }

    /// Meshes are deliberately not supplied: `makeVisual` returns nil without one,
    /// so no `ModelEntity` is built, while every link entity and every joint origin
    /// is. Those are what this suite compares, and skipping the 41 STL decodes keeps
    /// it a unit test.
    private static func graph(_ urdf: URDFDocument) -> RobotSceneGraph {
        RobotSceneGraph(urdf: urdf, meshes: [:], geometry: StewartGeometry(urdf: urdf))
    }

    @Test("the graph's root carries URDF's Z-up into RealityKit's Y-up")
    func rootRotationIsTheOneThisSuiteAssumes() throws {
        let graph = try Self.graph(Self.document())
        expectClose(
            simd_double4x4(graph.root.transform.matrix),
            Self.zUpToYUp,
            label: "root"
        )
    }

    @Test("every visual is placed identically by the flattening and by the graph")
    func flatteningAgreesWithTheEntityTree() throws {
        let urdf = try Self.document()
        let graph = Self.graph(urdf)
        let placements = urdf.flattenedVisuals()

        #expect(placements.isEmpty == false)
        // The description's own visuals, in the order `flattenedVisuals()` walks
        // them, so a placement can be paired with the `<visual>` it came from —
        // there is nothing in the entity tree to match one against, since an
        // uncoloured mesh child is not named.
        let visuals = urdf.links.flatMap { link in
            link.visuals.compactMap { visual -> (String, URDFVisual)? in
                guard case .mesh = visual.geometry else { return nil }
                return (link.name, visual)
            }
        }
        #expect(placements.count == visuals.count)

        for (placement, pair) in zip(placements, visuals) {
            let (linkName, visual) = pair
            #expect(placement.link == linkName)
            guard let entity = graph.entity(forLink: linkName) else {
                Issue.record("\(linkName) has no entity in the graph")
                continue
            }
            // Both sides are in the URDF's own frame, and that is the point of
            // measuring relative to `graph.root` rather than to the scene: the
            // rotation lives *on* `root`, so everything under it is still Z-up.
            // The link's transform there carries every joint origin between it and
            // the base, and the visual's offset is the child transform
            // `makeVisual` would have applied.
            let fromGraph = simd_double4x4(entity.transformMatrix(relativeTo: graph.root))
                * visual.origin.matrix
            expectClose(placement.transform, fromGraph, label: "\(linkName)/\(placement.mesh)")
        }
    }

    @Test("every flattened mesh is one the bundle actually carries")
    func namesOnlyBundledMeshes() throws {
        let urdf = try Self.document()
        let bundled = BundledRobotGeometry.meshFilenames
        let named = Set(urdf.flattenedVisuals().map(\.mesh))
        #expect(named.subtracting(bundled).isEmpty)
        // The same 41 the description draws — `visualMeshFilenames` is the existing
        // answer and this one may not become a second, narrower one.
        #expect(named == urdf.visualMeshFilenames)
    }

    /// The exporter leaves the antennas out by naming their joints, so what the
    /// walk has to get right is the whole subtree below each — the antenna link
    /// carries `antenna.stl` and nothing else does, but a filter that only knew
    /// about the mesh would keep any child link that appeared later.
    @Test("the antenna joints name a subtree, and dropping it drops antenna.stl")
    func antennaSubtreeIsExcludable() throws {
        let urdf = try Self.document()
        let excluded = ["left_antenna", "right_antenna"]
            .reduce(into: Set<String>()) { $0.formUnion(urdf.linksBelow(jointNamed: $1)) }

        #expect(excluded.count == 2)
        #expect(urdf.flattenedVisuals().map(\.mesh).contains("antenna.stl"))

        let kept = urdf.flattenedVisuals(excluding: excluded)
        #expect(kept.map(\.mesh).contains("antenna.stl") == false)
        #expect(kept.count < urdf.flattenedVisuals().count)
        // Only the antennas go: every other link the description draws survives,
        // which is what stops an over-wide walk from quietly shrinking the model
        // a tracker is fitted to.
        #expect(Set(kept.map(\.link)) == Set(urdf.flattenedVisuals().map(\.link)).subtracting(excluded))
    }

    @Test("a joint the description does not have excludes nothing")
    func unknownJointExcludesNothing() throws {
        let urdf = try Self.document()
        #expect(urdf.linksBelow(jointNamed: "third_antenna").isEmpty)
    }

    /// An uncoloured `<visual>` has to reach a file and the screen in the same
    /// grey, which is why the default moved onto `URDFColor` rather than staying a
    /// literal in `RobotSceneGraph.makeVisual`.
    @Test("an uncoloured visual is resolved through the shared default")
    func uncolouredVisualTakesTheSharedDefault() throws {
        let link = URDFLink(name: "solo", visuals: [
            URDFVisual(
                origin: .identity,
                geometry: .mesh(filename: "part.stl", scale: SIMD3(1, 1, 1)),
                color: nil
            ),
        ])
        let urdf = try URDFDocument(name: "one", links: [link], joints: [])
        #expect(urdf.flattenedVisuals().map(\.color) == [.unspecifiedVisual])
    }

    /// Float is what RealityKit stores, so the graph's side of every comparison has
    /// already been through a narrowing conversion. 1e-5 over transforms whose
    /// translations are centimetres leaves three orders of magnitude between a
    /// rounding difference and a real one.
    private func expectClose(
        _ lhs: simd_double4x4,
        _ rhs: simd_double4x4,
        label: String,
        tolerance: Double = 1e-5,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for column in 0 ..< 4 {
            let difference = simd_length(lhs[column] - rhs[column])
            #expect(
                difference < tolerance,
                "\(label): column \(column) differs by \(difference)",
                sourceLocation: sourceLocation
            )
        }
    }
}

private extension simd_double4x4 {
    init(_ matrix: simd_float4x4) {
        self.init(
            SIMD4<Double>(matrix.columns.0),
            SIMD4<Double>(matrix.columns.1),
            SIMD4<Double>(matrix.columns.2),
            SIMD4<Double>(matrix.columns.3)
        )
    }
}
