// The robot's layers as SVG, the vector format Icon Composer takes for a layer.

import CoreGraphics
import Foundation

/// One layer as an SVG document on the 1024-point canvas: one `<path>` per shape, so
/// shapes that overlap (an antenna's rod and its cap) both paint, whatever the
/// winding of each.
func svgDocument(_ layer: RobotLayer) -> String {
    let side = Int(canvasSide)
    let fill = String(format: "#%06X", layer.color)
    let paths = layer.paths.map { "<path fill=\"\(fill)\" d=\"\(svgPathData($0))\"/>" }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(side)" height="\(side)" viewBox="0 0 \(side) \(side)">
    \(paths.joined(separator: "\n"))
    </svg>

    """
}

/// SVG path data for `path`, two decimals a coordinate: a hundredth of a point is
/// far below anything the icon is ever drawn at, and a fixed format keeps a re-run
/// byte-identical.
func svgPathData(_ path: CGPath) -> String {
    var commands: [String] = []
    path.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint:
            commands.append("M" + svgPoints([points[0]]))
        case .addLineToPoint:
            commands.append("L" + svgPoints([points[0]]))
        case .addQuadCurveToPoint:
            commands.append("Q" + svgPoints([points[0], points[1]]))
        case .addCurveToPoint:
            commands.append("C" + svgPoints([points[0], points[1], points[2]]))
        case .closeSubpath:
            commands.append("Z")
        @unknown default:
            fatalError("Unknown path element")
        }
    }
    return commands.joined()
}

private func svgPoints(_ points: [CGPoint]) -> String {
    points.map { String(format: "%.2f %.2f", $0.x, $0.y) }.joined(separator: " ")
}
