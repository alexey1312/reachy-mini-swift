// Scales a simulator screenshot to a store size and writes it without an alpha channel.
//
//   swift screenshots/tvos/opaque.swift <in.png> <out.png> <width> <height>
//
// `simctl io screenshot` writes RGBA, opaque or not, and `sips` keeps the channel through
// every conversion but JPEG, which blurs the text. Drawing into a context with no alpha
// (`noneSkipLast`) makes ImageIO write plain RGB, the way the icon renderer writes its
// opaque layers (`Scripts/render-app-icon/Drawing.swift`).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 5, let width = Int(arguments[3]), let height = Int(arguments[4]),
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fatalError("usage: opaque.swift <in.png> <out.png> <width> <height>")
}

let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not write \(arguments[2])")
}
