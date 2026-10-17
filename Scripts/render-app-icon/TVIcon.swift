import CoreGraphics
import Foundation

// MARK: - tvOS

/// One picture in the TV app's brand assets: a layer of an image stack or a top shelf image.
struct TVPicture {
    let name: String
    let opaque: Bool
    let draw: (CGContext, CGRect) -> Void
}

/// A centred square, `fraction` of the canvas's height, for the robot to be drawn in.
func robotSquare(in rect: CGRect, fraction: CGFloat) -> CGRect {
    let side = rect.height * fraction
    return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
}

/// `picture` at every scale, as `name.png`, `name@2x.png` and so on (the name in lower
/// case), in a new image set.
func writeTVImageSet(_ set: URL, _ picture: TVPicture, width: Int, height: Int, scales: [Int]) throws {
    let file = picture.name.lowercased()
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    var images: [[String: Any]] = []
    for scale in scales {
        let name = scale == 1 ? "\(file).png" : "\(file)@\(scale)x.png"
        let image = renderCanvas(width: width * scale, height: height * scale, opaque: picture.opaque, picture.draw)
        writePNG(image, to: set.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "tv", "scale": "\(scale)x"])
    }
    try writeJSON(["images": images, "info": catalogueInfo], to: set.appendingPathComponent("Contents.json"))
}

func writeTVStack(_ stack: URL, layers: [TVPicture], width: Int, height: Int, scales: [Int]) throws {
    for layer in layers {
        let folder = stack.appendingPathComponent("\(layer.name).imagestacklayer")
        let set = folder.appendingPathComponent("Content.imageset")
        try writeTVImageSet(set, layer, width: width, height: height, scales: scales)
        try writeJSON(["info": catalogueInfo], to: folder.appendingPathComponent("Contents.json"))
    }
    let names = layers.map { ["filename": "\($0.name).imagestacklayer"] }
    try writeJSON(["info": catalogueInfo, "layers": names], to: stack.appendingPathComponent("Contents.json"))
}

func tvAsset(_ filename: String, role: String, size: String) -> [String: Any] {
    ["filename": filename, "idiom": "tv", "role": role, "size": size]
}

/// tvOS takes no `.icon` either. Its icon and top shelf images are an asset catalogue's
/// brand assets, which App Store Connect requires: two image stacks — the Home Screen
/// icon (400 x 240 pt, @1x and @2x) and the App Store one (1280 x 768, @1x) — with the
/// visionOS split, which the system moves apart under focus, and two flat top shelf
/// images (1920 x 720 and 2320 x 720 pt). The robot is 80 % of the icon's height so the
/// parallax does not crop the antenna tips. The names are Xcode's own, because the
/// target names the set in `ASSETCATALOG_COMPILER_APPICON_NAME`. The default theme only.
func writeTVIcon(_ theme: IconTheme, to catalogue: URL) throws {
    let brand = catalogue.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
    try? FileManager.default.removeItem(at: catalogue)
    try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
    try writeJSON(["info": catalogueInfo], to: catalogue.appendingPathComponent("Contents.json"))

    let robot = { (parts: RobotParts) in
        { (ctx: CGContext, rect: CGRect) in
            drawRobot(ctx, content: robotSquare(in: rect, fraction: 0.8), parts: parts) }
    }
    let layers = [
        TVPicture(name: "Front", opaque: false, draw: robot(.eyes)),
        TVPicture(name: "Middle", opaque: false, draw: robot(.shell)),
        TVPicture(name: "Back", opaque: true) { drawGradient($0, $1, theme) },
    ]
    let shelf = TVPicture(name: "Shelf", opaque: true) { ctx, rect in
        drawGradient(ctx, rect, theme)
        drawRobot(ctx, content: robotSquare(in: rect, fraction: 0.7))
    }
    try writeTVStack(
        brand.appendingPathComponent("App Icon.imagestack"),
        layers: layers,
        width: 400,
        height: 240,
        scales: [1, 2]
    )
    try writeTVStack(
        brand.appendingPathComponent("App Icon - App Store.imagestack"), layers: layers, width: 1280, height: 768,
        scales: [1]
    )
    for (name, width) in [("Top Shelf Image", 1920), ("Top Shelf Image Wide", 2320)] {
        let set = brand.appendingPathComponent("\(name).imageset")
        try writeTVImageSet(set, shelf, width: width, height: 720, scales: [1, 2])
    }
    let assets = [
        tvAsset("App Icon - App Store.imagestack", role: "primary-app-icon", size: "1280x768"),
        tvAsset("App Icon.imagestack", role: "primary-app-icon", size: "400x240"),
        tvAsset("Top Shelf Image Wide.imageset", role: "top-shelf-image-wide", size: "2320x720"),
        tvAsset("Top Shelf Image.imageset", role: "top-shelf-image", size: "1920x720"),
    ]
    try writeJSON(["assets": assets, "info": catalogueInfo], to: brand.appendingPathComponent("Contents.json"))
    print("wrote \(brand.path)")
}
