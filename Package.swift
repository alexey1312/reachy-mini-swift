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
        // 26 because LiveKit's WebRTC slices for these two require it on visionOS and
        // RealityView requires it on tvOS. `platforms:` sets minimums and is not an
        // allow-list, so naming them adds no build of any kind.
        .tvOS("26.0"),
        .visionOS("26.0"),
    ],
    products: [
        .library(name: "HuggingFaceAuth", targets: ["HuggingFaceAuth"]),
        .library(name: "ReachyDesign", targets: ["ReachyDesign"]),
        .library(name: "ReachyKit", targets: ["ReachyKit"]),
        .library(name: "ReachyMedia", targets: ["ReachyMedia"]),
        .library(name: "ReachyScene", targets: ["ReachyScene"]),
        .library(name: "ReachySimulator", targets: ["ReachySimulator"]),
        .library(name: "ReachySSH", targets: ["ReachySSH"]),
        .library(name: "ReachyTeleop", targets: ["ReachyTeleop"]),
        .library(name: "ReachyUI", targets: ["ReachyUI"]),
        .library(name: "ReachyWidgetUI", targets: ["ReachyWidgetUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.14.3"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.3"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.4.0"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "156.0.0"),
        // The same library for tvOS and visionOS, which stasel ships no slice for.
        // `exact:` because its version is Chromium's milestone and build, not semver,
        // and `ReachyMedia` names its symbols by hand (`WebRTCNames.swift`).
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.04"),
        // Pre-1.0, where a minor bump is a breaking change, so `upToNextMinor`
        // rather than the `from:` every other dependency here uses.
        .package(url: "https://github.com/orlandos-nl/Citadel", .upToNextMinor(from: "0.12.1")),
        // No target here uses these two; `Apps/Project.swift` does. Declared so SwiftPM (and
        // Dependabot) pin the same 25 packages Xcode does instead of dropping five of them.
        .package(url: "https://github.com/BarredEwe/Prefire", exact: "6.5.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.7"),
    ],
    targets: [
        // This app's own Hugging Face session — sign-in, token custody, renewal.
        // Nothing here knows what a robot is: it depends on Foundation, CryptoKit
        // and Security alone, and a target boundary is what keeps it that way.
        // The robot's *own* account (`/api/hf-auth/*`) is a daemon surface and
        // stays in ReachyKit — which does not depend on this target either, so a
        // token reaches it as a value the UI passes in, never as a global.
        .target(name: "HuggingFaceAuth", dependencies: ["ReachyJSON", "ReachyKeychain"]),
        // Every hand-written JSON call in this repository, and the rules each kind
        // of payload is read under. A leaf on Foundation alone because `ReachySSH`
        // and `HuggingFaceAuth` deliberately do not depend on `ReachyKit` — see
        // docs/adr/0004-one-json-codec.md.
        .target(name: "ReachyJSON", exclude: ["AGENTS.md", "CLAUDE.md"]),
        // The Keychain calls of `HuggingFaceAuth` and `ReachySSH`, in one place: on macOS the
        // data protection keychain and the move out of the file-based one. A leaf on
        // Foundation and Security, for the reason `ReachyJSON` is one.
        .target(name: "ReachyKeychain", exclude: ["AGENTS.md", "CLAUDE.md"]),
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
            // Two builds of one library, one per platform pair. LiveKit's carries an
            // `LK` prefix on every symbol, which `WebRTCNames.swift` maps back.
            dependencies: [
                "ReachyKit",
                .product(name: "WebRTC", package: "WebRTC", condition: .when(platforms: [.iOS, .macOS])),
                .product(
                    name: "LiveKitWebRTC",
                    package: "webrtc-xcframework",
                    condition: .when(platforms: [.tvOS, .visionOS])
                ),
            ],
            exclude: ["AGENTS.md", "CLAUDE.md"]
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
            // Citadel on iOS and macOS only: its fork of swift-nio-ssh imports `NIO`
            // without depending on it, which fails the tvOS and visionOS builds. There
            // `RobotFileSystems.ssh(robot:)` answers nil, as for a robot with no address.
            dependencies: [
                .product(name: "Citadel", package: "Citadel", condition: .when(platforms: [.iOS, .macOS])),
                "ReachyJSON",
                "ReachyKeychain",
            ],
            exclude: ["AGENTS.md", "CLAUDE.md"]
        ),
        // Driving the robot live: the pad's mapping, the game controller and the driver
        // that turns both into one target. A target of its own so that a surface with
        // no ReachyUI — the TV app — drives through the same code the phone does.
        // Nothing here draws: ReachyDesign is linked for the strings and the preview
        // switch, ReachyKit for the channel a target goes out on.
        .target(
            name: "ReachyTeleop",
            dependencies: ["ReachyDesign", "ReachyKit"],
            exclude: ["AGENTS.md", "CLAUDE.md"]
        ),
        .target(
            name: "ReachyUI",
            // `ReachyWidgetUI` for the app artwork alone, which both the store
            // rows and the widget's tiles draw. The arrow points this way round on
            // purpose: the widget target must stay clear of ReachyMedia.
            dependencies: [
                "HuggingFaceAuth", "ReachyDesign", "ReachyJSON", "ReachyKit", "ReachyMedia", "ReachyScene",
                "ReachySimulator", "ReachySSH", "ReachyTeleop", "ReachyWidgetUI",
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
            // `ReachyKit` for the frame it publishes and the kinematics it runs —
            // `StewartIK`, `TargetSlewLimiter` and `RobotStateFrame` are all the
            // real client's, so the simulator cannot drift from what a robot does
            // by reimplementing any of them.
            // `ReachyJSON` for the one payload it has to build rather than read:
            // the daemon status, which rule 11 says goes through `JSONCodec.daemon`
            // like every other thing the robot would have said.
            dependencies: ["ReachyJSON", "ReachyKit"],
            exclude: ["AGENTS.md", "CLAUDE.md"],
            resources: [.process("Resources")]
        ),
        // Not a product: stubs for the test targets only, in a plain target because
        // one test target cannot import another's sources.
        .target(name: "ReachyTestSupport", dependencies: ["ReachyKeychain"]),
        // Also not a product, and not shipped at all: it writes the USD scene an
        // object tracker is trained from (#77), out of the description and meshes
        // `ReachySimulator` already carries. An executable rather than a
        // `Scripts/*.swift` because a script cannot link a target — `URDFParser`
        // and `STLDecoder` would have to be copied, and a robot exported by a
        // second decoder is one that can drift from the robot on screen.
        .executableTarget(
            name: "ReachyGeometryExport",
            dependencies: ["ReachyKit", "ReachySimulator"]
        ),
        .testTarget(
            name: "ReachyDesignTests",
            dependencies: ["ReachyDesign"]
        ),
        .testTarget(
            name: "ReachyJSONTests",
            dependencies: ["ReachyJSON"]
        ),
        .testTarget(
            name: "ReachyKeychainTests",
            dependencies: ["ReachyKeychain", "ReachyTestSupport"]
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
            // `ReachySimulator` for its bundled description alone, the reason
            // `ReachyKitTests` takes it: the property `URDFFlatteningTests` holds is
            // about the *real* robot's 162 visuals composing identically two ways,
            // and a synthetic fixture cannot fail the way a 41-mesh chain can.
            dependencies: ["ReachyScene", "ReachyKit", "ReachySimulator"]
        ),
        .testTarget(
            name: "ReachySimulatorTests",
            // `ReachyKit` because the assertion worth making is that the *app's own*
            // parsers read what is bundled: `URDFParser` and `STLDecoder`, not a
            // second reader written for the test.
            dependencies: ["ReachySimulator", "ReachyKit"]
        ),
        .testTarget(
            name: "ReachyMediaTests",
            // `WebRTC` by name because the tests stand up the robot's half of a session
            // themselves — a second peer connection in the same process, offering the way
            // the robot's `webrtcsink` does.
            dependencies: ["ReachyMedia", "ReachyKit", .product(name: "WebRTC", package: "WebRTC")]
        ),
        .testTarget(
            name: "ReachySSHTests",
            dependencies: ["ReachySSH", "ReachyTestSupport"]
        ),
        .testTarget(
            name: "ReachyTeleopTests",
            dependencies: ["ReachyTeleop", "ReachyKit"]
        ),
        .testTarget(
            name: "ReachyUITests",
            // `ReachyMedia` for `CameraSession`: the viewport now borrows one from
            // a remote session instead of always building its own, and that
            // ownership is what its tests have to assert on. `ReachyWidgetUI` for
            // the two entity types `ReachyEntityIndex` stamps — named explicitly
            // rather than leaned on as a transitive import of `ReachyUI`, and
            // `ReachySimulator` for the client a simulated viewport source carries.
            dependencies: [
                "ReachyUI", "ReachyKit", "ReachyMedia", "ReachySimulator", "ReachyTeleop", "ReachyWidgetUI",
                "HuggingFaceAuth",
            ]
        ),
        .testTarget(
            name: "ReachyWidgetUITests",
            dependencies: ["ReachyWidgetUI", "ReachyKit"]
        ),
    ]
)
