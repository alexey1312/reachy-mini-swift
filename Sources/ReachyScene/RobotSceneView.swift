// `RealityView` lives in the RealityKit/SwiftUI cross-import overlay. Xcode wires
// that up automatically; SwiftPM does not, so the overlay module is named here.
import _RealityKit_SwiftUI
import RealityKit
import SwiftUI

/// Renders the robot and lets the user orbit and zoom around it.
public struct RobotSceneView: View {
    private let model: RobotSceneModel
    #if os(visionOS)
        /// Carries the robot at this view's scale and position; see `scene`.
        @State private var stand = Entity()
    #endif

    public init(model: RobotSceneModel) {
        self.model = model
    }

    public var body: some View {
        scene
            // The camera frames the robot against the **narrower** field of view, so it has
            // to be told the shape of the rectangle it is drawing into. Read here rather
            // than in a `GeometryReader` because this view has no layout of its own to hang
            // one on, and because the column's width changes under a finger on the divider —
            // `frame(_:)` re-runs on each new value and nothing else does.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                model.camera.aspect = size.height > 0 ? Float(size.width / size.height) : 1
            }
            .gesture(orbit)
            .simultaneousGesture(zoom)
    }

    #if os(visionOS)
        /// **visionOS ignores the camera, and that moved two things out of the window.**
        /// A window draws a `RealityView`'s entities at real size from the centre of the view,
        /// so the robot stood 0.39 m tall from the middle and rose past the window's top edge.
        /// And the view took the window's whole offered depth, 540 pt, so the 2D overlays above
        /// it lay on its front face, 540 pt nearer the eye than the window, where perspective
        /// pushed the view switcher out past the leading edge and the pad past the trailing one.
        ///
        /// So here the view claims no depth, which keeps every overlay on the window's plane,
        /// and `fit(into:)` scales the robot into the view and stands it in front of that plane.
        private var scene: some View {
            // Read here, in the body, so the robot is placed again once its meshes exist.
            let ready = model.phase == .ready
            return GeometryReader3D { proxy in
                RealityView { content in
                    stand.addChild(model.container)
                    content.add(stand)
                } update: { content in
                    guard ready else { return }
                    fit(into: content.convert(proxy.frame(in: .local), from: .local, to: .scene))
                }
            }
            .frame(depth: 0)
        }

        /// The share of the view the robot fills. It stands in front of the window,
        /// so perspective draws it larger and, from an eye above the middle, lower:
        /// at 0.8 its base reached past the window's bottom edge in the simulator.
        private static let fill: Float = 0.7

        /// Turns the robot to the angle the orbit camera starts from on the other platforms,
        /// scales it to `fill` of the view, centres it, and stands it on the window's plane.
        ///
        /// The bounds are the ones measured when the robot was built, in the container's
        /// own space, so the scale never reads back the scale it set. The live bounds
        /// would not do: a sleeping head is lower, and a robot fitted while asleep
        /// would outgrow the window when it wakes.
        private func fit(into frame: BoundingBox) {
            guard let bounds = model.builtBounds else { return }
            let height = bounds.extents.y
            // A body of revolution about the vertical axis: its width does not change as it turns.
            let width = max(bounds.extents.x, bounds.extents.z)
            guard height > 0, width > 0, frame.extents.x > 0, frame.extents.y > 0 else { return }
            let scale = Self.fill * min(frame.extents.x / width, frame.extents.y / height)
            let turn = simd_quatf(angle: -OrbitCamera.startingAzimuth, axis: [0, 1, 0])
            let target = SIMD3(frame.center.x, frame.center.y, frame.max.z + scale * width / 2)
            stand.orientation = turn
            stand.scale = SIMD3(repeating: scale)
            stand.position = target - scale * turn.act(bounds.center)
        }
    #else
        private var scene: some View {
            RealityView { content in
                // The robot, its lighting and the camera angle are all reused across a
                // teardown; only the camera entity is rebuilt, because the active-camera
                // role belongs to the scene rather than to the entity carrying it.
                content.entities.append(model.container)
                // The scene supplies its own camera, so RealityKit's built-in controls
                // are off — they frame the scene once, at a point where the robot has
                // not downloaded yet.
                content.entities.append(model.camera.makeEntity())
            } update: { _ in
                // Intentionally empty: poses are written to the entity tree directly,
                // so SwiftUI is not in the 20 Hz path.
            }
        }
    #endif

    private var orbit: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.camera.drag(translation: SIMD2(
                    Float(value.translation.width),
                    Float(value.translation.height)
                ))
            }
            .onEnded { _ in model.camera.endGesture() }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in model.camera.magnify(by: Float(value.magnification)) }
            .onEnded { _ in model.camera.endGesture() }
    }
}
