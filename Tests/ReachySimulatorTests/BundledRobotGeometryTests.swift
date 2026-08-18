import Foundation
import ReachyKit
import ReachySimulator
import Testing

/// What a bundle of vendored assets can get wrong, and nothing else would catch.
///
/// The scene is built by `RobotGeometryProvider` from two calls, so the failure
/// modes here are all packaging: a mesh the description names and the bundle
/// lacks, a file that came across as a Git LFS pointer instead of its bytes, a
/// description that no longer parses. Each of them renders as an empty or broken
/// robot at runtime with nothing in the log, which is why they are asserted at
/// build time instead.
@Suite("Bundled robot geometry")
struct BundledRobotGeometryTests {
    private let geometry = BundledRobotGeometry()

    // The description's *shape* — 45 links, the nine actuators, the 21 passive
    // joints, the head's chain — is asserted by `RealURDFTests` in ReachyKitTests,
    // which reads this same bundled file and was written long before there was one
    // to read. Nothing here repeats it.

    /// **The assertion the whole target rests on.** `RobotGeometryProvider` asks
    /// for exactly `visualMeshFilenames`, so a description naming one mesh more
    /// than the bundle carries is a robot that never finishes loading — and a
    /// bundle carrying one more than the description names is dead weight in an
    /// app that pays for it by the megabyte.
    @Test("every mesh the description draws is bundled, and no others")
    func bundleMatchesTheDescription() throws {
        let document = try URDFParser.parse(geometry.urdf())

        #expect(document.visualMeshFilenames == BundledRobotGeometry.meshFilenames)
    }

    /// Upstream keeps these in Git LFS, where the plain raw URL serves a 131-byte
    /// pointer rather than the mesh. One that slipped through would be a valid
    /// *file* and an invalid STL, so decoding every one of them is the check —
    /// `STLDecoder` is the same reader the app uses on what a robot sends.
    @Test("every bundled mesh decodes, and none is an LFS pointer")
    func everyMeshDecodes() throws {
        let names = BundledRobotGeometry.meshFilenames
        #expect(names.count == 41)

        for name in names.sorted() {
            let data = try geometry.stlAsset(named: name)
            let mesh = try STLDecoder.decode(data)
            #expect(!mesh.positions.isEmpty, "\(name) decoded to no geometry")
            #expect(mesh.indices.count % 3 == 0, "\(name) has a partial triangle")
        }
    }

    @Test("a mesh that is not there is named, not silently empty")
    func missingAssetIsNamed() {
        #expect(throws: BundledRobotGeometry.Failure.missingAsset("nothing.stl")) {
            try geometry.stlAsset(named: "nothing.stl")
        }
    }
}
