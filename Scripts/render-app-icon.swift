// Renders the Hey Reachy app icons — one Icon Composer bundle per ReachyTheme —
// deterministically: same code, same bytes. Run from the repo root after changing
// the design:
//
//   ./bin/mise run theme:icons
//
// Each bundle holds the identical robot glyph on transparency; only icon.json's
// background gradient differs. `actool` generates everything else from that: the
// light, dark and tinted appearances, the iOS 18–25 back-deployment rasters and the
// macOS ladder. There is deliberately no asset catalogue — a same-named
// `.appiconset` is shadowed by the `.icon` and contributes nothing.
//
// visionOS is the exception: it takes no `.icon` bundle, so the same drawing also
// writes the visionOS app's layered image stack (`writeVisionIcon` at the end).

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

// MARK: - Themes

/// A duplicate of `ReachyTheme.palette`'s gradient stops, for the reason
/// `render-theme-colors.swift` carries one of the accents: a script run by `swift`
/// cannot link `ReachyDesign`. `ThemeIconNameTests.iconGradientMatchesPalette` reads
/// the generated documents back and is what catches the two copies drifting apart —
/// it does not keep them together, so edit both by hand.
struct IconTheme {
    let bundleName: String
    let gradientTop: UInt32
    let gradientBottom: UInt32
}

let iconThemes = [
    IconTheme(bundleName: "AppIcon", gradientTop: 0x9AA6B8, gradientBottom: 0x3E4757),
    IconTheme(bundleName: "AppIcon-Bronze", gradientTop: 0xFFC96B, gradientBottom: 0xB26708),
    IconTheme(bundleName: "AppIcon-Teal", gradientTop: 0x5FE0CE, gradientBottom: 0x00A0A8),
    IconTheme(bundleName: "AppIcon-Indigo", gradientTop: 0x9B9BF5, gradientBottom: 0x4B47D6),
    IconTheme(bundleName: "AppIcon-Orchid", gradientTop: 0xE8AEFF, gradientBottom: 0x9038D9),
    IconTheme(bundleName: "AppIcon-Rose", gradientTop: 0xFFA8CE, gradientBottom: 0xD6248A),
]

// MARK: - Output

/// Icon Composer writes a fill stop as a colour-space prefix and four fractions.
/// `srgb:` rather than `display-p3:` because the palette constants are sRGB and a
/// conversion here would be a second place for a colour to be defined.
func fillStop(_ hex: UInt32) -> String {
    String(
        format: "srgb:%.5f,%.5f,%.5f,1.00000",
        Double((hex >> 16) & 0xFF) / 255,
        Double((hex >> 8) & 0xFF) / 255,
        Double(hex & 0xFF) / 255
    )
}

func writeIconBundle(_ theme: IconTheme, glyph: CGImage, in resources: URL) throws {
    let bundle = resources.appendingPathComponent("\(theme.bundleName).icon")
    try? FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(
        at: bundle.appendingPathComponent("Assets"),
        withIntermediateDirectories: true
    )
    writePNG(glyph, to: bundle.appendingPathComponent("Assets/robot.png"))

    let document: [String: Any] = [
        "fill": ["linear-gradient": [fillStop(theme.gradientTop), fillStop(theme.gradientBottom)]],
        "groups": [[
            "layers": [["image-name": "robot.png", "name": "Robot"]],
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": false, "value": 0.5],
        ]],
        "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
    ]
    // `.sortedKeys` is what makes a re-run byte-identical; without it the dictionary's
    // order is the hash order and every run dirties the diff.
    let data = try JSONSerialization.data(
        withJSONObject: document,
        options: [.prettyPrinted, .sortedKeys]
    )
    let json = String(data: data, encoding: .utf8)! + "\n"
    try json.write(to: bundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote \(bundle.path)")
}

let resources = URL(fileURLWithPath: "Apps/ReachyMini/Resources")
let glyph = renderGlyph(pixels: 1024)
for theme in iconThemes {
    try writeIconBundle(theme, glyph: glyph, in: resources)
}

// MARK: - visionOS

/// A square layer in a top-left user space. `opaque` drops the alpha channel, which
/// visionOS requires of the back layer.
func renderLayer(pixels: Int, opaque: Bool = false, _ draw: (CGContext, CGRect) -> Void) -> CGImage {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alpha.rawValue
    )!
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx, CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return ctx.makeImage()!
}

func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (String(data: data, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
}

/// visionOS takes no `.icon` bundle. Its app icon is a solid image stack: square
/// layers of 1024 px that the system masks to a circle and moves apart as the reader
/// looks at it. The same drawing, split by depth — the theme's gradient at the back,
/// the antennas and the shell in the middle, the goggles in front — and drawn smaller,
/// so the antenna tips stay inside the circle. The default theme only, because
/// visionOS offers no alternate icons.
func writeVisionIcon(_ theme: IconTheme, to catalogue: URL) throws {
    let pixels = 1024
    let info: [String: Any] = ["author": "xcode", "version": 1]
    let stack = catalogue.appendingPathComponent("AppIcon.solidimagestack")
    try? FileManager.default.removeItem(at: catalogue)
    try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
    try writeJSON(["info": info], to: catalogue.appendingPathComponent("Contents.json"))

    let inset = CGFloat(pixels) * 0.07
    let robot = { (ctx: CGContext, rect: CGRect, parts: RobotParts) in
        drawRobot(ctx, content: rect.insetBy(dx: inset, dy: inset), parts: parts)
    }
    let layers: [(name: String, image: CGImage)] = [
        ("Front", renderLayer(pixels: pixels) { robot($0, $1, .eyes) }),
        ("Middle", renderLayer(pixels: pixels) { robot($0, $1, .shell) }),
        ("Back", renderLayer(pixels: pixels, opaque: true) { ctx, rect in
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
        }),
    ]
    for layer in layers {
        let folder = stack.appendingPathComponent("\(layer.name).solidimagestacklayer")
        let imageSet = folder.appendingPathComponent("Content.imageset")
        try FileManager.default.createDirectory(at: imageSet, withIntermediateDirectories: true)
        try writeJSON(["info": info], to: folder.appendingPathComponent("Contents.json"))
        let file = "\(layer.name.lowercased()).png"
        writePNG(layer.image, to: imageSet.appendingPathComponent(file))
        try writeJSON(
            ["images": [["filename": file, "idiom": "vision", "scale": "2x"]], "info": info],
            to: imageSet.appendingPathComponent("Contents.json")
        )
    }
    try writeJSON(
        ["info": info, "layers": layers.map { ["filename": "\($0.name).solidimagestacklayer"] }],
        to: stack.appendingPathComponent("Contents.json")
    )
    print("wrote \(stack.path)")
}

try writeVisionIcon(iconThemes[0], to: URL(fileURLWithPath: "Apps/ReachyVision/Resources/Assets.xcassets"))
