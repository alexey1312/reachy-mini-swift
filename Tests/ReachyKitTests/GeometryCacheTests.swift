@testable import ReachyKit
import Testing

struct GeometryCacheTests {
    @Test func refusesMeshNamesThatEscapeTheCache() {
        #expect(!GeometryCache.isSafeMeshName(""))
        #expect(!GeometryCache.isSafeMeshName(".."))
        #expect(!GeometryCache.isSafeMeshName("../evil.stl"))
        #expect(!GeometryCache.isSafeMeshName("meshes/../../evil.stl"))
        #expect(!GeometryCache.isSafeMeshName("a\\b.stl"))
    }

    @Test func acceptsOrdinaryMeshNames() {
        #expect(GeometryCache.isSafeMeshName("head.stl"))
        #expect(GeometryCache.isSafeMeshName("stewart_1.stl"))
        #expect(GeometryCache.isSafeMeshName("body rotation.stl"))
    }
}
