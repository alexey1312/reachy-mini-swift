#!/usr/bin/env swift

// Renders the App Store screenshot artboards to exactly the pixel sizes App Store
// Connect demands.
//
// The artboards are HTML because that is what the design pass produces, and the
// renderer is WKWebView because it is the one browser engine already on a Mac —
// Node, Chrome and Playwright are none of them installed here, and `bootstrap.sh`
// forbids reaching for a global install.
//
// **The whole trick is that the artboards are authored in output pixels rather than
// points.** An iPhone 6.5" screenshot is 1242x2688, so the page declares a 1242x2688
// body and the web view is given a 1242x2688 *point* frame. That sidesteps the one
// thing this approach cannot control: `takeSnapshot` renders at the screen's backing
// scale, which is 2 on a Retina Mac and 1 on anything else. At 1x the capture is
// already the exact size; at 2x it is a supersample, which is downscaled here and
// comes out sharper than a direct render would. Authoring in points and hoping for
// 3x would depend on hardware nobody has.
//
// Usage: swift Scripts/render-store-screenshots.swift <input-dir> <output-dir>
// See `mise run screenshots:store`.

import AppKit
import WebKit

/// Keyed by the filename prefix the design pass uses, so a new family is one row.
struct Family {
    let prefix: String
    let width: Int
    let height: Int
}

let sizes = [
    // IMESSAGE_APP_IPHONE_65 — `asc screenshots sizes --all` also accepts 1284x2778.
    Family(prefix: "iphone", width: 1242, height: 2688),
    // IMESSAGE_APP_IPAD_PRO_3GEN_129 — 2064x2752 is accepted too.
    Family(prefix: "ipad", width: 2048, height: 2732),
]

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: \(arguments[0]) <input-dir> <output-dir>\n".utf8))
    exit(2)
}

let input = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let pages = (try? FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension == "html" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
guard !pages.isEmpty else {
    FileHandle.standardError.write(Data("no .html artboards in \(input.path)\n".utf8))
    exit(1)
}

/// Resamples to the exact target, which is a no-op at 1x and a downscale at 2x.
func exactly(_ image: CGImage, width: Int, height: Int) -> CGImage {
    if image.width == width, image.height == height {
        return image
    }
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

/// WKWebView needs a live application and a run loop, so the script drives one
/// rather than blocking on a semaphore — a snapshot taken off the main run loop
/// never arrives.
final class Renderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var remaining: [URL]
    private let output: URL
    private struct Job {
        let url: URL
        let width: Int
        let height: Int
    }

    private var current: Job?
    private var failures = 0

    init(pages: [URL], output: URL) {
        remaining = pages
        self.output = output
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        next()
    }

    private func next() {
        guard let page = remaining.first else {
            print(failures == 0 ? "rendered \(output.path)" : "\(failures) artboard(s) failed")
            exit(failures == 0 ? 0 : 1)
        }
        remaining.removeFirst()
        let name = page.deletingPathExtension().lastPathComponent
        guard let size = sizes.first(where: { name.hasPrefix($0.prefix) }) else {
            let known = sizes.map(\.prefix).joined(separator: ", ")
            FileHandle.standardError.write(Data(
                "\(name): no size for this prefix — name it after one of \(known), or add a row\n".utf8
            ))
            failures += 1
            next()
            return
        }
        current = Job(url: page, width: size.width, height: size.height)
        webView.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Layout and image decoding both finish after `didFinish`; a snapshot taken
        // immediately catches a half-drawn page with the images missing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.capture() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        report(error)
    }

    private func report(_ error: Error) {
        let name = current?.url.lastPathComponent ?? "?"
        FileHandle.standardError.write(Data("\(name): \(error.localizedDescription)\n".utf8))
        failures += 1
        next()
    }

    private func capture() {
        guard let job = current else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: job.width, height: job.height)
        configuration.snapshotWidth = NSNumber(value: job.width)
        webView.takeSnapshot(with: configuration) { image, error in
            defer { self.next() }
            guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                let reason = error?.localizedDescription ?? "no image"
                FileHandle.standardError.write(
                    Data("\(job.url.lastPathComponent): \(reason)\n".utf8)
                )
                self.failures += 1
                return
            }
            let exact = exactly(cgImage, width: job.width, height: job.height)
            let destination = self.output
                .appendingPathComponent(job.url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("png")
            write(exact, to: destination)
            print("  \(destination.lastPathComponent)  \(exact.width)x\(exact.height)")
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let renderer = Renderer(pages: pages, output: output)
DispatchQueue.main.async { renderer.start() }
application.run()
