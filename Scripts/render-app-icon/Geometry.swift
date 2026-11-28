// The robot as vector shapes, once, for every platform's icon.
//
// Every shape is a `CGPath` in Icon Composer's canvas: a 1024-point square with a
// top-left origin. The `.icon` bundles take the paths as SVG (`SVG.swift`), which
// actool keeps as vectors, so the icon stays sharp at any size the system draws it.
// visionOS and tvOS take bitmaps, so `Drawing.swift` fills the same paths into them.

import CoreGraphics

/// The side of Icon Composer's canvas for iPhone, iPad and Mac, in points.
let canvasSide: CGFloat = 1024

/// The parts of the robot, so visionOS and tvOS can put them on layers of different depth.
struct RobotParts: OptionSet {
    let rawValue: Int
    /// The antennas and the head's shell.
    static let shell = RobotParts(rawValue: 1)
    /// The goggles.
    static let eyes = RobotParts(rawValue: 2)
    static let all: RobotParts = [.shell, .eyes]
}

/// One layer of the icon: a name, the shapes, and the colour the shapes carry in the
/// light appearance. The other appearances recolour a layer in `icon.json`, so the
/// shapes stay identical in all six bundles.
struct RobotLayer {
    let name: String
    let part: RobotParts
    let paths: [CGPath]
    let color: UInt32
    /// A flat layer, without the Liquid Glass material. Only the glints are flat:
    /// they already are the light on the lens.
    var glass = true

    var fileName: String {
        "\(name.lowercased()).svg"
    }
}

/// A group of layers that Liquid Glass lights, shadows and moves as one piece.
struct RobotGroup {
    let name: String
    let layers: [RobotLayer]
    let shadow: Double
}

let ink: UInt32 = 0x1D1D1F
let white: UInt32 = 0xFFFFFF
let black: UInt32 = 0x000000
let rim: UInt32 = 0x55565C

// MARK: - Shape

/// The head's centre, before the tilt.
private let headCenter = CGPoint(x: 512, y: 596)
private let headSize = CGSize(width: 648, height: 456)

/// The greeting: the whole robot leans a few degrees, like a head tilt.
private let tilt = CGAffineTransform(translationX: headCenter.x, y: headCenter.y)
    .rotated(by: -6 * .pi / 180)
    .translatedBy(x: -headCenter.x, y: -headCenter.y)

private func tilted(_ path: CGPath) -> CGPath {
    var transform = tilt
    return path.copy(using: &transform)!
}

/// One cubic segment of a continuous corner, in corner radii from the corner point:
/// `x` along the edge the path arrives on, `y` along the edge it leaves on.
private struct CornerCurve {
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint
}

/// The distance from a corner point at which a continuous corner leaves the straight edge,
/// in corner radii.
private let cornerReach: CGFloat = 1.528_665

private let cornerCurves = [
    CornerCurve(
        control1: CGPoint(x: 1.088_493, y: 0),
        control2: CGPoint(x: 0.868_407, y: 0),
        end: CGPoint(x: 0.631_494, y: 0.074_911)
    ),
    CornerCurve(
        control1: CGPoint(x: 0.372_824, y: 0.169_052),
        control2: CGPoint(x: 0.169_052, y: 0.372_824),
        end: CGPoint(x: 0.074_911, y: 0.631_494)
    ),
    CornerCurve(
        control1: CGPoint(x: 0, y: 0.868_407),
        control2: CGPoint(x: 0, y: 1.088_493),
        end: CGPoint(x: 0, y: cornerReach)
    ),
]

/// A corner of a rectangle: the corner point, and the unit vectors back along the edge
/// the path arrives on (`u`) and forward along the edge it leaves on (`v`).
private struct Corner {
    let point: CGPoint
    let u: CGVector
    let v: CGVector

    /// `offset`, in corner radii of `radius`, as a point in the rectangle's space.
    func place(_ offset: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x + radius * (offset.x * u.dx + offset.y * v.dx),
            y: point.y + radius * (offset.x * u.dy + offset.y * v.dy)
        )
    }
}

/// A rounded rectangle with continuous corners, the curve iOS draws for
/// `RoundedRectangle(style: .continuous)`. A circular corner meets the straight edge
/// with a visible kink; this one does not, and the head reads as one smooth shape.
func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    precondition(cornerReach * radius <= min(rect.width, rect.height) / 2, "corner radius too large")
    // Clockwise from the top trailing corner.
    let corners = [
        Corner(point: CGPoint(x: rect.maxX, y: rect.minY), u: CGVector(dx: -1, dy: 0), v: CGVector(dx: 0, dy: 1)),
        Corner(point: CGPoint(x: rect.maxX, y: rect.maxY), u: CGVector(dx: 0, dy: -1), v: CGVector(dx: -1, dy: 0)),
        Corner(point: CGPoint(x: rect.minX, y: rect.maxY), u: CGVector(dx: 1, dy: 0), v: CGVector(dx: 0, dy: -1)),
        Corner(point: CGPoint(x: rect.minX, y: rect.minY), u: CGVector(dx: 0, dy: 1), v: CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    for (index, corner) in corners.enumerated() {
        let edgeEnd = corner.place(CGPoint(x: cornerReach, y: 0), radius: radius)
        if index == 0 {
            path.move(to: edgeEnd)
        } else {
            path.addLine(to: edgeEnd)
        }
        for curve in cornerCurves {
            path.addCurve(
                to: corner.place(curve.end, radius: radius),
                control1: corner.place(curve.control1, radius: radius),
                control2: corner.place(curve.control2, radius: radius)
            )
        }
    }
    path.closeSubpath()
    return path
}

/// A capsule `width` wide on a line out of `root`, from `start` to `end` points along
/// it. `angle` 0 is straight up; a positive angle leans toward the trailing edge.
private func capsule(root: CGPoint, angle: CGFloat, from start: CGFloat, to end: CGFloat, width: CGFloat) -> CGPath {
    var place = CGAffineTransform(translationX: root.x, y: root.y).rotated(by: angle)
    let rect = CGRect(x: -width / 2, y: -end, width: width, height: end - start)
    return CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: &place)
}

private func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(
        ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius),
        transform: nil
    )
}

private let head = CGRect(
    x: headCenter.x - headSize.width / 2,
    y: headCenter.y - headSize.height / 2,
    width: headSize.width,
    height: headSize.height
)

/// Reachy Mini's antennas: a thin rod with a thicker cap at the tip, not a ball.
/// The roots sit inside the head, which covers them.
private let antennas: [CGPath] = [-1, 1].flatMap { (side: CGFloat) -> [CGPath] in
    let root = CGPoint(x: headCenter.x + side * 178, y: head.minY + 48)
    let angle = side * 15 * .pi / 180
    return [
        capsule(root: root, angle: angle, from: 0, to: 274, width: 28),
        capsule(root: root, angle: angle, from: 190, to: 300, width: 40),
    ]
}

/// The goggles: two lenses joined by a bridge, Reachy's signature face.
private let lensRadius: CGFloat = 104
private let lensCenters = [-1, 1].map { (side: CGFloat) in
    CGPoint(x: headCenter.x + side * 152, y: headCenter.y + 8)
}

/// A rim round each lens.
private let rims: [CGPath] = lensCenters.map { circle($0, lensRadius) }

/// The lenses and the bridge between them, in one colour: a grey bridge thinned out to
/// nothing at 29 pt.
private let lenses: [CGPath] = lensCenters.map { circle($0, lensRadius - 16) } + [
    CGPath(
        rect: CGRect(
            x: lensCenters[0].x,
            y: lensCenters[0].y - 17,
            width: lensCenters[1].x - lensCenters[0].x,
            height: 34
        ),
        transform: nil
    ),
]

/// A catchlight, upper-leading on each lens: the lens reads as glass, not paint.
private let glints: [CGPath] = lensCenters.map {
    circle(CGPoint(x: $0.x - 38, y: $0.y - 38), 27)
}

// MARK: - Layers

/// Front to back, the order `icon.json` lists them in.
let robotGroups: [RobotGroup] = [
    RobotGroup(name: "Goggles", layers: [
        RobotLayer(name: "Glints", part: .eyes, paths: glints.map(tilted), color: white, glass: false),
        RobotLayer(name: "Lenses", part: .eyes, paths: lenses.map(tilted), color: ink),
        RobotLayer(name: "Rims", part: .eyes, paths: rims.map(tilted), color: rim),
    ], shadow: 0.35),
    RobotGroup(name: "Head", layers: [
        RobotLayer(name: "Shell", part: .shell, paths: [tilted(continuousRect(head, radius: 140))], color: white),
    ], shadow: 0.5),
    RobotGroup(name: "Antennas", layers: [
        RobotLayer(name: "Antennas", part: .shell, paths: antennas.map(tilted), color: ink),
    ], shadow: 0.3),
]

/// Every layer, front to back.
let robotLayers = robotGroups.flatMap(\.layers)
