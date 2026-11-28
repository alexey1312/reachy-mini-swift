// The bitmap renderer for visionOS and tvOS, and the file writers every icon shares.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

// MARK: - Drawing

/// Fills the robot's paths into `content`, a square in a top-left user space: the
/// bitmap twin of the SVG layers, for visionOS and tvOS. `parts` picks the layers.
func drawRobot(_ ctx: CGContext, content: CGRect, parts: RobotParts = .all) {
    ctx.saveGState()
    ctx.translateBy(x: content.minX, y: content.minY)
    ctx.scaleBy(x: content.width / canvasSide, y: content.height / canvasSide)
    // Back to front, so each layer covers the ones behind it.
    for layer in robotLayers.reversed() where parts.contains(layer.part) {
        ctx.setFillColor(srgb(layer.color))
        for path in layer.paths {
            ctx.addPath(path)
            ctx.fillPath()
        }
    }
    ctx.restoreGState()
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write \(url.path)")
    }
    print("wrote \(url.path)")
}

// MARK: - Layered icons

/// A layer in a top-left user space. `opaque` drops the alpha channel, which visionOS
/// requires of an icon's back layer, and tvOS of that and of a top shelf image.
func renderCanvas(width: Int, height: Int, opaque: Bool = false, _ draw: (CGContext, CGRect) -> Void) -> CGImage {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alpha.rawValue
    )!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx, CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// The theme's gradient, top to bottom, over the whole canvas: every back layer.
func drawGradient(_ ctx: CGContext, _ rect: CGRect, _ theme: IconTheme) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [srgb(theme.gradientTop), srgb(theme.gradientBottom)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.maxY),
        options: []
    )
}

func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (String(data: data, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
}

let catalogueInfo: [String: Any] = ["author": "xcode", "version": 1]
