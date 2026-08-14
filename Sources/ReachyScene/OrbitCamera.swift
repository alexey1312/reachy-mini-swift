import RealityKit
import simd

/// Camera that circles a fixed point, driven by gestures.
///
/// RealityKit's built-in orbit controls frame whatever the scene contains when
/// the view is first made. The robot arrives over the network seconds later, so
/// they end up framing nothing and park the camera inside the model — hence a
/// controller that can re-frame once the geometry is actually there.
@MainActor
public final class OrbitCamera {
    /// Replaced per `RealityView`: see `makeEntity()`.
    public private(set) var entity = PerspectiveCamera()

    /// A fresh camera for a newly made `RealityView`.
    ///
    /// Carrying one `PerspectiveCamera` from a torn-down view into its replacement
    /// leaves the new scene with no active camera — the entity is present and the
    /// robot is present, but nothing is rendered from anywhere, which is why the
    /// viewport came back empty. Everything else about the scene survives the swap
    /// and is deliberately reused; only the camera is rebuilt, and it inherits the
    /// angle the user had.
    public func makeEntity() -> PerspectiveCamera {
        entity = PerspectiveCamera()
        entity.name = "camera"
        apply()
        return entity
    }

    /// Rotation around the vertical axis.
    private var azimuth: Float = .pi * 0.85
    /// Height above the horizon, clamped short of the poles where the up vector
    /// degenerates and the view flips.
    private var elevation: Float = 0.42
    private var distance: Float = 0.6
    private var target: SIMD3<Float> = .zero

    private var startAzimuth: Float?
    private var startElevation: Float?
    private var startDistance: Float?

    private var minimumDistance: Float = 0.05
    private var maximumDistance: Float = 5

    private static let maximumElevation: Float = .pi / 2 - 0.05
    /// Radians per point of drag — a full turn takes roughly a screen width.
    private static let dragSensitivity: Float = 0.01

    public init() {
        entity.name = "camera"
        apply()
    }

    private var framedBounds: BoundingBox?

    /// Width ÷ height of the view this camera renders into, so `frame(_:)` can back off
    /// when width is the dimension that runs out first.
    ///
    /// It shipped without this and the robot was cropped down its sides in the trailing
    /// column — 280 pt wide against 1210 tall.
    public var aspect: Float = 1 {
        didSet {
            guard aspect != oldValue, let framedBounds else { return }
            frame(framedBounds)
        }
    }

    /// RealityKit's default vertical field of view.
    private static let verticalFieldOfView: Float = 60 * .pi / 180

    /// How far back the model has to be to be seen whole in a view of this shape.
    ///
    /// **Two measurements, and using the wrong one for the horizontal check is the
    /// mistake this signature exists to prevent.** The vertical fit is the historical
    /// `sphereRadius * 2.2` — exactly `1 / sin(30°) · 1.1`, a bounding _sphere_ inside a
    /// 60° field with a tenth to spare — and it is kept as a floor so this can only ever
    /// pull back, never crowd a view that already framed correctly.
    ///
    /// The horizontal check takes `groundRadius` instead — the model's own half-width
    /// across the ground plane, not the sphere's. **The sphere is nearly twice as wide
    /// as this robot** (0.189 against 0.09), so checking width against it defends
    /// against an overhang that does not exist. An iPhone in portrait is aspect ≈ 0.52,
    /// which is *also* taller than it is wide, so a sphere-based check reached it too:
    /// 66 % of extra distance and half the robot on every phone, to protect the empty
    /// corners of a bounding box.
    ///
    /// `groundRadius` is `max(x, z) / 2` and not the ground diagonal, because this model
    /// is a body of revolution about the vertical axis — the antennas go up, not out —
    /// so its silhouette does not widen as the camera orbits. The diagonal is a box's
    /// answer, and it costs a phone 12 % for corners that hold air. Measured at the
    /// shipping bounds: it is the diagonal that clips 2.5 % on an iPhone in portrait,
    /// and `max(x, z)` that does not.
    static func distance(sphereRadius: Float, groundRadius: Float, aspect: Float) -> Float {
        let vertical = verticalFieldOfView
        let horizontal = 2 * atan(tan(vertical / 2) * max(aspect, 0.01))
        let byHeight = sphereRadius / sin(vertical / 2) * 1.1
        let byWidth = groundRadius / tan(horizontal / 2) * 1.1
        return max(byHeight, byWidth)
    }

    /// Restores the starting three-quarter view.
    public func reset() {
        azimuth = .pi * 0.85
        elevation = 0.42
        endGesture()
        if let framedBounds {
            frame(framedBounds)
        } else {
            apply()
        }
    }

    /// Points the camera at the model and backs off far enough to see all of it.
    public func frame(_ bounds: BoundingBox) {
        framedBounds = bounds
        target = bounds.center
        let radius = max(simd_length(bounds.extents) / 2, 0.01)
        let ground = max(max(bounds.extents.x, bounds.extents.z) / 2, 0.01)
        distance = Self.distance(sphereRadius: radius, groundRadius: ground, aspect: aspect)
        minimumDistance = radius * 0.6
        maximumDistance = radius * 12
        apply()
    }

    public func drag(translation: SIMD2<Float>) {
        let azimuthStart = startAzimuth ?? azimuth
        let elevationStart = startElevation ?? elevation
        startAzimuth = azimuthStart
        startElevation = elevationStart
        azimuth = azimuthStart - translation.x * Self.dragSensitivity
        elevation = (elevationStart + translation.y * Self.dragSensitivity)
            .clamped(to: -Self.maximumElevation ... Self.maximumElevation)
        apply()
    }

    public func magnify(by scale: Float) {
        let start = startDistance ?? distance
        startDistance = start
        distance = (start / max(scale, 0.01)).clamped(to: minimumDistance ... maximumDistance)
        apply()
    }

    /// Gestures report cumulative values, so the anchor is captured on the first
    /// change and released when the gesture ends.
    public func endGesture() {
        startAzimuth = nil
        startElevation = nil
        startDistance = nil
    }

    private func apply() {
        let horizontal = distance * cos(elevation)
        let position = target + SIMD3(
            horizontal * sin(azimuth),
            distance * sin(elevation),
            horizontal * cos(azimuth)
        )
        entity.look(at: target, from: position, relativeTo: nil)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
