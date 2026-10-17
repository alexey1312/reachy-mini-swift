// The robot, drawn once for every platform's icon, and the file writers the icons share.

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

let shell = srgb(0xFFFFFF)
let shellShade = srgb(0xF2E9E1)
let ink = srgb(0x1D1D1F)
let sparkle = srgb(0xFFFFFF, alpha: 0.85)

// MARK: - Drawing

/// The parts of the robot, so visionOS can put them on layers of different depth.
struct RobotParts: OptionSet {
    let rawValue: Int
    /// The antennas and the head's shell.
    static let shell = RobotParts(rawValue: 1)
    /// The goggles.
    static let eyes = RobotParts(rawValue: 2)
    static let all: RobotParts = [.shell, .eyes]
}

/// Draws the robot into `content`, a square in the context's user space.
func drawRobot(_ ctx: CGContext, content: CGRect, parts: RobotParts = .all) {
    let s = content.width
    let headCenter = CGPoint(x: content.midX, y: content.midY + 0.075 * s)

    ctx.saveGState()
    // The greeting: the whole robot leans a few degrees, like a head tilt.
    ctx.translateBy(x: headCenter.x, y: headCenter.y)
    ctx.rotate(by: -6 * .pi / 180)
    ctx.translateBy(x: -headCenter.x, y: -headCenter.y)

    let headSize = CGSize(width: 0.66 * s, height: 0.48 * s)
    let head = CGRect(
        x: headCenter.x - headSize.width / 2,
        y: headCenter.y - headSize.height / 2,
        width: headSize.width,
        height: headSize.height
    )

    if parts.contains(.shell) {
        drawAntennas(ctx, side: s, headCenter: headCenter, headTop: head.minY)
        drawHead(ctx, side: s, head: head)
    }
    if parts.contains(.eyes) {
        drawEyes(ctx, side: s, headCenter: headCenter)
    }

    ctx.restoreGState()
}

/// Antennas go first, so the head covers their roots.
func drawAntennas(_ ctx: CGContext, side s: CGFloat, headCenter: CGPoint, headTop: CGFloat) {
    let length = 0.26 * s
    let spread: CGFloat = 17 * .pi / 180
    for side: CGFloat in [-1, 1] {
        let root = CGPoint(x: headCenter.x + side * 0.20 * s, y: headTop + 0.06 * s)
        let tip = CGPoint(
            x: root.x + side * sin(spread) * length,
            y: root.y - cos(spread) * length
        )
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(0.024 * s)
        ctx.setLineCap(.round)
        ctx.strokeLineSegments(between: [root, tip])
        ctx.setFillColor(ink)
        let dot = 0.036 * s
        ctx.fillEllipse(in: CGRect(x: tip.x - dot, y: tip.y - dot, width: 2 * dot, height: 2 * dot))
    }
}

func drawHead(_ ctx: CGContext, side s: CGFloat, head: CGRect) {
    let headPath = CGPath(
        roundedRect: head,
        cornerWidth: 0.16 * s,
        cornerHeight: 0.16 * s,
        transform: nil
    )
    ctx.addPath(headPath)
    ctx.setFillColor(shell)
    ctx.fillPath()

    // A soft shade along the bottom edge keeps the shell from reading flat.
    ctx.saveGState()
    ctx.addPath(headPath)
    ctx.clip()
    ctx.setFillColor(shellShade)
    ctx.fill(CGRect(x: head.minX, y: head.maxY - 0.10 * s, width: head.width, height: 0.10 * s))
    ctx.restoreGState()
}

/// Goggle eyes: two lenses joined by a bridge, Reachy's signature face.
func drawEyes(_ ctx: CGContext, side s: CGFloat, headCenter: CGPoint) {
    let eyeRadius = 0.088 * s
    let eyeY = headCenter.y - 0.01 * s
    let eyeOffset = 0.14 * s
    let left = CGPoint(x: headCenter.x - eyeOffset, y: eyeY)
    let right = CGPoint(x: headCenter.x + eyeOffset, y: eyeY)

    ctx.setStrokeColor(ink)
    ctx.setLineWidth(0.020 * s)
    ctx.strokeLineSegments(between: [left, right])

    for center in [left, right] {
        ctx.setFillColor(ink)
        ctx.fillEllipse(in: CGRect(
            x: center.x - eyeRadius, y: center.y - eyeRadius,
            width: 2 * eyeRadius, height: 2 * eyeRadius
        ))
        // Specular dot, upper-leading — the lens looks glassy, not painted.
        let hl = 0.028 * s
        ctx.setFillColor(sparkle)
        ctx.fillEllipse(in: CGRect(
            x: center.x - 0.035 * s - hl, y: center.y - 0.035 * s - hl,
            width: 2 * hl, height: 2 * hl
        ))
    }
}

/// The robot on transparency. Every `.icon` bundle carries this same image; only the
/// background gradient in `icon.json` tells the six themes apart.
func renderGlyph(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Flip to top-left origin so the drawing reads like the design.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: 1, y: -1)
    drawRobot(ctx, content: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return ctx.makeImage()!
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
