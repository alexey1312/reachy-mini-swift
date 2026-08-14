@testable import ReachyScene
import RealityKit
import simd
import Testing

@MainActor
@Suite("Orbit camera")
struct OrbitCameraTests {
    /// A Reachy Mini is roughly 28 cm tall and stands on the origin.
    private var robotBounds: BoundingBox {
        BoundingBox(min: SIMD3(-0.09, 0, -0.09), max: SIMD3(0.09, 0.28, 0.09))
    }

    /// The bug this class exists to fix: framing an empty scene left the camera at
    /// the origin, which is inside the robot once it finally loads.
    @Test("framing puts the camera outside the model")
    func framingEscapesTheModel() {
        let camera = OrbitCamera()
        camera.frame(robotBounds)
        let position = camera.entity.position(relativeTo: nil)
        #expect(simd_distance(position, robotBounds.center) > simd_length(robotBounds.extents) / 2)
    }

    @Test("framing scales the distance to the model, not to a fixed guess")
    func framingScalesWithSize() {
        let near = OrbitCamera()
        near.frame(robotBounds)
        let far = OrbitCamera()
        far.frame(BoundingBox(min: SIMD3(-1, 0, -1), max: SIMD3(1, 3, 1)))

        let nearDistance = simd_distance(near.entity.position(relativeTo: nil), robotBounds.center)
        let farDistance = simd_distance(far.entity.position(relativeTo: nil), SIMD3(0, 1.5, 0))
        #expect(farDistance > nearDistance * 5)
    }

    @Test("dragging changes the viewpoint but keeps the distance")
    func draggingOrbits() {
        let camera = OrbitCamera()
        camera.frame(robotBounds)
        let before = camera.entity.position(relativeTo: nil)

        camera.drag(translation: SIMD2(120, 0))
        let after = camera.entity.position(relativeTo: nil)

        #expect(simd_distance(before, after) > 0.01)
        let radiusBefore = simd_distance(before, robotBounds.center)
        let radiusAfter = simd_distance(after, robotBounds.center)
        #expect(abs(radiusBefore - radiusAfter) < 1e-4)
    }

    /// Past the pole the up vector degenerates and the image flips over.
    @Test("elevation stops short of straight overhead")
    func elevationIsClamped() {
        let camera = OrbitCamera()
        camera.frame(robotBounds)
        camera.drag(translation: SIMD2(0, 100_000))
        let position = camera.entity.position(relativeTo: nil)
        let horizontal = simd_length(SIMD2(position.x - robotBounds.center.x, position.z - robotBounds.center.z))
        #expect(horizontal > 0.001)
    }

    @Test("pinching in moves the camera closer")
    func magnifyPullsIn() {
        let camera = OrbitCamera()
        camera.frame(robotBounds)
        let before = simd_distance(camera.entity.position(relativeTo: nil), robotBounds.center)

        camera.magnify(by: 2)
        let after = simd_distance(camera.entity.position(relativeTo: nil), robotBounds.center)
        #expect(after < before)
    }

    /// Gestures report cumulative values; without releasing the anchor a second
    /// drag would restart from the original angle and the view would jump.
    @Test("a new gesture continues from where the last one stopped")
    func gesturesCompose() {
        let camera = OrbitCamera()
        camera.frame(robotBounds)

        camera.drag(translation: SIMD2(60, 0))
        camera.endGesture()
        let afterFirst = camera.entity.position(relativeTo: nil)

        camera.drag(translation: SIMD2(60, 0))
        let afterSecond = camera.entity.position(relativeTo: nil)
        #expect(simd_distance(afterFirst, afterSecond) > 0.01)
    }

    /// Switching the viewport to the camera and back tears the `RealityView` down and
    /// builds a new one. Carrying one `PerspectiveCamera` across that leaves the new
    /// scene with no active camera: the robot, its lighting and the right scene are all
    /// present and nothing whatever is drawn. So each view gets its own camera — which
    /// has to arrive already holding the angle the user dragged to, or every switch
    /// would snap the view back to the default three-quarters.
    @Test("each view gets a fresh camera, at the angle the last one had")
    func makeEntityIsFreshAndKeepsTheViewpoint() {
        let camera = OrbitCamera()
        camera.frame(robotBounds)
        camera.drag(translation: SIMD2(90, 0))
        camera.endGesture()
        let first = camera.entity
        let viewpoint = first.position(relativeTo: nil)

        let second = camera.makeEntity()
        #expect(second !== first)
        #expect(camera.entity === second)
        #expect(simd_distance(second.position(relativeTo: nil), viewpoint) < 1e-5)
    }

    /// The controller has to write to whichever camera is in the scene now; driving the
    /// discarded one would leave the view frozen after a switch.
    @Test("gestures drive the newest camera, not the discarded one")
    func gesturesFollowTheNewestCamera() {
        let camera = OrbitCamera()
        camera.frame(robotBounds)
        let discarded = camera.entity
        let current = camera.makeEntity()
        let before = discarded.position(relativeTo: nil)

        camera.drag(translation: SIMD2(120, 0))
        #expect(simd_distance(current.position(relativeTo: nil), before) > 0.01)
        #expect(simd_distance(discarded.position(relativeTo: nil), before) < 1e-5)
    }

    @Test("zooming cannot pass through the model or fly away")
    func zoomIsBounded() {
        let camera = OrbitCamera()
        camera.frame(robotBounds)

        camera.magnify(by: 1000)
        let closest = simd_distance(camera.entity.position(relativeTo: nil), robotBounds.center)
        #expect(closest > 0.01)

        camera.endGesture()
        camera.magnify(by: 0.0001)
        let farthest = simd_distance(camera.entity.position(relativeTo: nil), robotBounds.center)
        #expect(farthest < 10)
    }

    /// The shipping robot's two radii, which is what makes the numbers below mean
    /// something: the bounding **sphere** is nearly twice as wide as the robot, and
    /// which of the two the horizontal check uses is the whole design of `distance`.
    private var sphereRadius: Float {
        simd_length(robotBounds.extents) / 2
    }

    private var groundRadius: Float {
        max(robotBounds.extents.x, robotBounds.extents.z) / 2
    }

    private func distance(aspect: Float) -> Float {
        OrbitCamera.distance(sphereRadius: sphereRadius, groundRadius: groundRadius, aspect: aspect)
    }

    /// **Every viewport that framed correctly before must frame identically now**, and
    /// that is a wider set than "wider than it is tall": the vertical fit is a floor, so
    /// the camera only ever moves back. `2.2` is `1 / sin(30°) · 1.1` — a bounding sphere
    /// inside a 60° field with a tenth to spare.
    ///
    /// **0.517 is an iPhone in portrait** (402 × 778) and it belongs in this list, not
    /// in the one below. It was in the wrong list once: an earlier version checked width
    /// against the sphere, which is nearly twice the robot, and would have shrunk the
    /// robot by half on every phone to protect the empty corners of a box.
    @Test("every viewport that framed correctly before is untouched")
    func correctlyFramedAspectsAreUnchanged() {
        let unchanged: Float = sphereRadius * 2.2
        let aspects: [Float] = [0.517, 0.69, 1, 1.43, 2, 16.0 / 9]
        for aspect in aspects {
            #expect(abs(distance(aspect: aspect) - unchanged) < 1e-5)
        }
    }

    /// The column is 280 pt wide against 1210 tall — aspect 0.23, where the robot really
    /// did hang out of both sides.
    @Test("a column too narrow for the robot backs the camera off")
    func narrowAspectsPullBack() {
        let unchanged = distance(aspect: 1)
        var previous = unchanged
        let aspects: [Float] = [0.4, 0.31, 0.23]
        for aspect in aspects {
            let pulled = distance(aspect: aspect)
            #expect(pulled > previous)
            previous = pulled
        }
        #expect(distance(aspect: 0.23) > unchanged * 1.5)
    }

    /// A drag on the divider changes the column's width while the scene is mounted, so
    /// the framing has to follow rather than be decided once when the robot arrives.
    @Test("changing the aspect re-frames a camera that has already framed")
    func aspectReframesInPlace() {
        let camera = OrbitCamera()
        camera.frame(robotBounds)
        let wide = simd_distance(camera.entity.position(relativeTo: nil), robotBounds.center)

        camera.aspect = 0.23
        let narrow = simd_distance(camera.entity.position(relativeTo: nil), robotBounds.center)

        #expect(narrow > wide)
    }
}
