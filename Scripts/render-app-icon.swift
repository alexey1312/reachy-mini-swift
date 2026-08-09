// Renders the Hey Reachy app icon into the asset catalogue, deterministically:
// same code, same bytes. Run from the repo root after changing the design:
//
//   swift Scripts/render-app-icon.swift
//
// iOS takes the full-bleed 1024 square and masks it itself; macOS does not mask,
// so its variants draw the Big Sur rounded rectangle (824/1024, radius 185) with
// transparent margins and are re-rendered as vectors at every ladder size.

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

let backgroundTop = srgb(0xFFB84D) // warm amber
let backgroundBottom = srgb(0xFF5A3C) // coral — also the app's AccentColor
let shell = srgb(0xFFFFFF)
let shellShade = srgb(0xF2E9E1)
let ink = srgb(0x1D1D1F)
let sparkle = srgb(0xFFFFFF, alpha: 0.85)

// MARK: - Drawing

/// Draws the robot into `content`, a square in the context's user space.
func drawRobot(_ ctx: CGContext, content: CGRect) {
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

    drawAntennas(ctx, side: s, headCenter: headCenter, headTop: head.minY)
    drawHead(ctx, side: s, head: head)
    drawEyes(ctx, side: s, headCenter: headCenter)

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

func drawGradient(_ ctx: CGContext, in rect: CGRect) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [backgroundTop, backgroundBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.maxY),
        options: []
    )
}

enum IconShape {
    case fullBleed // iOS: the system applies its own mask
    case macRoundedRect // macOS: the icon carries its shape and margins itself
}

func render(pixels: Int, shape: IconShape) -> CGImage {
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

    let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    switch shape {
    case .fullBleed:
        drawGradient(ctx, in: canvas)
        drawRobot(ctx, content: canvas)
    case .macRoundedRect:
        // Big Sur geometry: an 824/1024 rounded rectangle, radius 185/1024.
        let inset = canvas.width * (100.0 / 1024.0)
        let plate = canvas.insetBy(dx: inset, dy: inset)
        let radius = canvas.width * (185.0 / 1024.0)
        let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        drawGradient(ctx, in: plate)
        drawRobot(ctx, content: plate)
        ctx.restoreGState()
    }
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

// MARK: - Output

let appIconSet = URL(fileURLWithPath: "Apps/ReachyMini/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)

writePNG(render(pixels: 1024, shape: .fullBleed), to: appIconSet.appendingPathComponent("icon-ios-1024.png"))
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(
        render(pixels: pixels, shape: .macRoundedRect),
        to: appIconSet.appendingPathComponent("icon-mac-\(pixels).png")
    )
}
