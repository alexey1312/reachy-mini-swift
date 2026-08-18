// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ReachyMini",
    // Required the moment a target carries a localized resource. English is the
    // source language of `ReachyDesign/Resources/Localizable.xcstrings`, the one
    // catalogue both executables read.
    defaultLocalization: "en",
    platforms: [
        // RealityView (the 3D robot viewer) is iOS 18 / macOS 15.
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "HuggingFaceAuth", targets: ["HuggingFaceAuth"]),
        .library(name: "ReachyDesign", targets: ["ReachyDesign"]),
        .library(name: "ReachyKit", targets: ["ReachyKit"]),
        .library(name: "ReachyMedia", targets: ["ReachyMedia"]),
        .library(name: "ReachyScene", targets: ["ReachyScene"]),
        .library(name: "ReachySimulator", targets: ["ReachySimulator"]),
        .library(name: "ReachySSH", targets: ["ReachySSH"]),
        .library(name: "ReachyUI", targets: ["ReachyUI"]),
        .library(name: "ReachyWidgetUI", targets: ["ReachyWidgetUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "150.0.0"),
        // Pre-1.0, where a minor bump is a breaking change, so `upToNextMinor`
        // rather than the `from:` every other dependency here uses.
        .package(url: "https://github.com/orlandos-nl/Citadel", .upToNextMinor(from: "0.9.2")),
    ],
    targets: [
        // This app's own Hugging Face session — sign-in, token custody, renewal.
        // Nothing here knows what a robot is: it depends on Foundation, CryptoKit
        // and Security alone, and a target boundary is what keeps it that way.
        // The robot's *own* account (`/api/hf-auth/*`) is a daemon surface and
        // stays in ReachyKit — which does not depend on this target either, so a
        // token reaches it as a value the UI passes in, never as a global.
        .target(name: "HuggingFaceAuth", dependencies: ["ReachyJSON"]),
        // Every hand-written JSON call in this repository, and the rules each kind
        // of payload is read under. A leaf on Foundation alone because `ReachySSH`
        // and `HuggingFaceAuth` deliberately do not depend on `ReachyKit` — see
        // docs/adr/0004-one-json-codec.md.
        .target(name: "ReachyJSON", exclude: ["AGENTS.md", "CLAUDE.md"]),
        // Tokens and the `ReachySurface` facade. It depends on SwiftUI and
        // nothing else, which is what lets both `ReachyUI` and `ReachyWidgetUI`
        // link it: a dependency is linked into a *target*, not into the place it
        // is called from, so anything heavier here would reach the widget too.
        .target(
            name: "ReachyDesign",
            exclude: ["AGENTS.md", "CLAUDE.md", "Previews"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "ReachyKit",
            dependencies: [
                "ReachyJSON",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            exclude: ["AGENTS.md", "CLAUDE.md"],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .target(
            name: "ReachyMedia",
            dependencies: [
                "ReachyKit",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .target(
            name: "ReachyScene",
            dependencies: ["ReachyKit"],
            exclude: ["AGENTS.md", "CLAUDE.md"]
        ),
        // SFTP to the robot, for the files the daemon API deliberately cannot
        // reach. Its own product rather than a corner of ReachyKit: the widget
        // extension links ReachyWidgetUI, which links ReachyKit, and a process
        // woken for a moment to draw two lines of text has no business loading
        // SwiftNIO. It knows nothing about robots — host, port and credentials
        // arrive as values, the way a Hugging Face token reaches ReachyKit.
        .target(
            name: "ReachySSH",
            dependencies: [.product(name: "Citadel", package: "Citadel"), "ReachyJSON"],
            exclude: ["AGENTS.md", "CLAUDE.md"]
        ),
        .target(
            name: "ReachyUI",
            // `ReachyWidgetUI` for the app artwork alone, which both the store
            // rows and the widget's tiles draw. The arrow points this way round on
            // purpose: the widget target must stay clear of ReachyMedia.
            dependencies: [
                "HuggingFaceAuth", "ReachyDesign", "ReachyJSON", "ReachyKit", "ReachyMedia", "ReachyScene",
                "ReachySSH", "ReachyWidgetUI",
            ],
            // `Previews` sits beside the views it documents but is compiled by the Xcode targets
            // in `Apps/`, not by this one: `#Preview` is an external macro whose implementation
            // ships inside Xcode's platform SDKs, so SwiftPM builds on the pinned swift.org
            // toolchain fail with "plugin for module 'PreviewsMacros' not found".
            exclude: ["AGENTS.md", "CLAUDE.md", "Previews"]
        ),
        // The widget's views, deliberately not in ReachyUI: that target links
        // ReachyMedia (WebRTC) and ReachyScene (RealityKit), and a widget
        // extension — woken for a moment, on a hard memory budget — has no
        // business loading a media stack to draw two lines of text.
        .target(
            name: "ReachyWidgetUI",
            dependencies: ["ReachyDesign", "ReachyJSON", "ReachyKit"],
            exclude: ["AGENTS.md", "CLAUDE.md", "Previews"]
        ),
        // A robot that is not there: upstream's own description and meshes, carried
        // rather than fetched, so `RobotGeometryProvider` builds the same scene over
        // no network at all. Foundation only — serving two files needs nothing else,
        // and the target that will eventually speak `RobotAPIClient` can take the
        // dependency when it has a reason to.
        //
        // Its own target rather than a corner of `ReachyKit` for the reason
        // `ReachySSH` is one: the widget extension links `ReachyWidgetUI`, which
        // links `ReachyKit`, and 9 MiB of geometry has no business in a process
        // woken for a moment to draw two lines of text.
        .target(
            name: "ReachySimulator",
            exclude: ["AGENTS.md", "CLAUDE.md"],
            resources: [.process("Resources")]
        ),
        // Not a product: stubs for the test targets only, in a plain target because
        // one test target cannot import another's sources.
        .target(name: "ReachyTestSupport"),
        .testTarget(
            name: "ReachyDesignTests",
            dependencies: ["ReachyDesign"]
        ),
        .testTarget(
            name: "ReachyJSONTests",
            dependencies: ["ReachyJSON"]
        ),
        .testTarget(
            name: "HuggingFaceAuthTests",
            dependencies: ["HuggingFaceAuth", "ReachyTestSupport"]
        ),
        .testTarget(
            name: "ReachyKitTests",
            // `ReachySimulator` for its bundled description alone: `RealURDFTests`
            // was gated on an environment variable pointing at a file pulled off a
            // daemon by hand, so it ran nowhere. The vendored URDF is that file.
            dependencies: ["ReachyKit", "ReachySimulator", "ReachyTestSupport"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "ReachySceneTests",
            dependencies: ["ReachyScene", "ReachyKit"]
        ),
        .testTarget(
            name: "ReachySimulatorTests",
            // `ReachyKit` because the assertion worth making is that the *app's own*
            // parsers read what is bundled: `URDFParser` and `STLDecoder`, not a
            // second reader written for the test.
            dependencies: ["ReachySimulator", "ReachyKit"]
        ),
        .testTarget(
            name: "ReachySSHTests",
            dependencies: ["ReachySSH"]
        ),
        .testTarget(
            name: "ReachyUITests",
            // `ReachyMedia` for `CameraSession`: the viewport now borrows one from
            // a remote session instead of always building its own, and that
            // ownership is what its tests have to assert on. `ReachyWidgetUI` for
            // the two entity types `ReachyEntityIndex` stamps — named explicitly
            // rather than leaned on as a transitive import of `ReachyUI`.
            dependencies: ["ReachyUI", "ReachyKit", "ReachyMedia", "ReachyWidgetUI", "HuggingFaceAuth"]
        ),
        .testTarget(
            name: "ReachyWidgetUITests",
            dependencies: ["ReachyWidgetUI", "ReachyKit"]
        ),
    ]
)
