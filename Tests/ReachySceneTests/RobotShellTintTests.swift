import CoreGraphics
import Foundation
@testable import ReachyKit
@testable import ReachyScene
import ReachySimulator
import RealityKit
import simd
import Testing

/// The theme's paint on the twin, read back off the materials themselves — the
/// component a frame is drawn from is the only honest signal, so nothing here asks
/// the graph what it believes it applied.
///
/// Meshes are one box under every name the description draws: `makeVisual` skips a
/// visual without a mesh, and with `meshes: [:]` there would be nothing to paint.
@MainActor
@Suite("Twin shell tint")
struct RobotShellTintTests {
    private static let teal = URDFColor(red: 0x9F / 255, green: 0xEC / 255, blue: 0xE2 / 255, alpha: 1)
    private static let white = URDFColor(red: 1, green: 1, blue: 1, alpha: 1)

    /// One visual, and it is shell: enough for the model to reach `.ready` with
    /// something to paint.
    private static let shellOnly = """
    <robot name="stub">
      <link name="body">
        <visual>
          <geometry><mesh filename="package://assets/body_top_3dprint.stl"/></geometry>
          <material name="white"><color rgba="1 1 1 1"/></material>
        </visual>
      </link>
    </robot>
    """

    @Test("every shell mesh is one the bundled robot actually draws")
    func shellNamesExist() {
        #expect(RobotShell.meshFilenames.isSubset(of: BundledRobotGeometry.meshFilenames))
    }

    @Test("the bundled robot has five shell parts, all factory white")
    func findsTheShell() throws {
        let graph = try Self.bundledGraph()
        #expect(graph.shellParts.count == 5)
        for part in graph.shellParts {
            try expectColor(part.entity, Self.white)
        }
    }

    @Test("a tint paints the shell and nothing else")
    func paintsOnlyTheShell() throws {
        let graph = try Self.bundledGraph()
        let shell = Set(graph.shellParts.map { ObjectIdentifier($0.entity) })
        let others = models(under: graph.root).filter { !shell.contains(ObjectIdentifier($0)) }
        let before = try others.map(rgba)
        #expect(!others.isEmpty)

        graph.applyShellTint(Self.teal)

        for part in graph.shellParts {
            try expectColor(part.entity, Self.teal)
        }
        #expect(try others.map(rgba) == before)
    }

    @Test("nil puts the description's own colour back")
    func nilRestores() throws {
        let graph = try Self.bundledGraph()
        graph.applyShellTint(Self.teal)
        graph.applyShellTint(nil)
        #expect(graph.shellTint == nil)
        for part in graph.shellParts {
            try expectColor(part.entity, Self.white)
        }
    }

    /// Observed rather than inferred: a material swapped in behind the graph's back
    /// survives a repeat of the tint already applied, which it would not if the
    /// repeat rebuilt the materials.
    @Test("repeating the applied tint touches nothing")
    func repeatIsANoOp() throws {
        let graph = try Self.bundledGraph()
        graph.applyShellTint(Self.teal)
        let part = try #require(graph.shellParts.first)
        let black = URDFColor(red: 0, green: 0, blue: 0, alpha: 1)
        let marker = SimpleMaterial(color: .init(red: 0, green: 0, blue: 0, alpha: 1), isMetallic: false)
        part.entity.model?.materials = [marker]

        graph.applyShellTint(Self.teal)

        try expectColor(part.entity, black)
    }

    @Test("a description with no shell in it is drawn in its own colours")
    func unknownDescriptionIsLeftAlone() throws {
        let urdf = try URDFParser.parse(SceneStubClient.oneLink)
        let graph = RobotSceneGraph(urdf: urdf, meshes: Self.boxes(for: urdf), geometry: nil)
        let visual = try #require(models(under: graph.root).first)
        let before = try rgba(visual)

        graph.applyShellTint(Self.teal)

        #expect(graph.shellParts.isEmpty)
        #expect(try rgba(visual) == before)
    }

    /// The only path that can paint here is the build: the tint was set while there
    /// was no graph, so its `didSet` had nothing to reach. Dropping the call in
    /// `build` leaves the robot white and this red.
    @Test("a tint set while loading is on the robot the moment it is ready")
    func tintSetBeforeReady() async throws {
        let model = makeModel()
        model.shellTint = Self.teal
        model.start()
        await waitUntil(model.phase == .ready)
        #expect(model.phase == .ready)

        let body = try #require(models(under: model.container).first)
        try expectColor(body, Self.teal)
        model.stop()
    }

    @Test("a tint set once the robot is ready applies at once, and nil undoes it")
    func tintSetAfterReady() async throws {
        let model = makeModel()
        model.start()
        await waitUntil(model.phase == .ready)
        let body = try #require(models(under: model.container).first)
        try expectColor(body, Self.white)

        model.shellTint = Self.teal
        try expectColor(body, Self.teal)
        model.shellTint = nil
        try expectColor(body, Self.white)
        model.stop()
    }

    // MARK: - Helpers

    private static func bundledGraph() throws -> RobotSceneGraph {
        let urdf = try URDFParser.parse(BundledRobotGeometry().urdf())
        return RobotSceneGraph(urdf: urdf, meshes: boxes(for: urdf), geometry: nil)
    }

    private static func boxes(for urdf: URDFDocument) -> [String: MeshResource] {
        let box = MeshResource.generateBox(size: 0.01)
        return Dictionary(uniqueKeysWithValues: urdf.visualMeshFilenames.map { ($0, box) })
    }

    private func makeModel() -> RobotSceneModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReachySceneShellTintTests/\(UUID().uuidString)", isDirectory: true)
        return RobotSceneModel(
            stream: nil,
            client: SceneStubClient(urdf: Self.shellOnly),
            cache: GeometryCache(root: root)
        )
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func models(under entity: Entity) -> [ModelEntity] {
        entity.children.flatMap { child -> [ModelEntity] in
            let own = (child as? ModelEntity).map { [$0] } ?? []
            return own + models(under: child)
        }
    }

    /// The base colour a visual renders with, normalised to sRGB — the platform
    /// colour a `SimpleMaterial` hands back need not be in the space it was built in.
    private func rgba(_ entity: ModelEntity) throws -> SIMD4<Double> {
        let material = try #require(entity.model?.materials.first as? SimpleMaterial)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let color = try #require(material.color.tint.cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil))
        let components = try #require(color.components)
        try #require(components.count == 4)
        return SIMD4(components.map { Double($0) })
    }

    private func expectColor(
        _ entity: ModelEntity,
        _ expected: URDFColor,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let actual = try rgba(entity)
        let wanted = SIMD4(expected.red, expected.green, expected.blue, expected.alpha)
        #expect(simd_distance(actual, wanted) < 1e-3, "\(actual) is not \(wanted)", sourceLocation: sourceLocation)
    }
}
