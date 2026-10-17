import CoreGraphics
import Foundation

// MARK: - visionOS

/// visionOS takes no `.icon` bundle. Its app icon is a solid image stack: square
/// layers of 1024 px that the system masks to a circle and moves apart as the reader
/// looks at it. The same drawing, split by depth — the theme's gradient at the back,
/// the antennas and the shell in the middle, the goggles in front — and drawn smaller,
/// so the antenna tips stay inside the circle. The default theme only, because
/// visionOS offers no alternate icons.
func writeVisionIcon(_ theme: IconTheme, to catalogue: URL) throws {
    let pixels = 1024
    let info = catalogueInfo
    let stack = catalogue.appendingPathComponent("AppIcon.solidimagestack")
    try? FileManager.default.removeItem(at: catalogue)
    try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
    try writeJSON(["info": info], to: catalogue.appendingPathComponent("Contents.json"))

    let inset = CGFloat(pixels) * 0.07
    let robot = { (ctx: CGContext, rect: CGRect, parts: RobotParts) in
        drawRobot(ctx, content: rect.insetBy(dx: inset, dy: inset), parts: parts)
    }
    let layers: [(name: String, image: CGImage)] = [
        ("Front", renderCanvas(width: pixels, height: pixels) { robot($0, $1, .eyes) }),
        ("Middle", renderCanvas(width: pixels, height: pixels) { robot($0, $1, .shell) }),
        ("Back", renderCanvas(width: pixels, height: pixels, opaque: true) { drawGradient($0, $1, theme) }),
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
