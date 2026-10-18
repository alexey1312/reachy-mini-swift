// Rewrites each PNG argument in place without an alpha channel, at the same size.
//
//   swift screenshots/visionos/flatten.swift screenshots/visionos/en-US/*.png
//
// The simulator's captures are opaque already; App Store Connect asks for flattened
// images, so the channel itself goes. Nothing is scaled or recoloured.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fatalError("cannot read \(path)") }
    let ctx = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(path)") }
    print("flattened \(path) \(image.width)x\(image.height)")
}
