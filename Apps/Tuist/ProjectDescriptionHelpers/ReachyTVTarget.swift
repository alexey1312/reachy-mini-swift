import ProjectDescription

public extension Target {
    /// The TV app: a focus-driven shell of its own over ReachyKit and ReachyTeleop, not a
    /// port of ReachyUI — that target does not compile for tvOS, and its screens are touch
    /// screens. It links no ReachyMedia yet, so it has no camera;
    /// `docs/research/tvos.md` says what that waits on.
    ///
    /// Here rather than in `Project.swift` only because that file is at SwiftLint's
    /// length limit. The version settings it reads are the project's own.
    static var reachyTV: Target {
        .target(
            name: "ReachyTV",
            destinations: [.appleTv],
            product: .app,
            // Its own identifier while it is a draft. Universal purchase with the iOS app
            // needs the same one, and that is a release decision.
            bundleId: "com.alexey1312.ReachyMini.TV",
            deploymentTargets: .tvOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": .string("Hey Reachy"),
                "CFBundleName": .string("Hey Reachy"),
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                "ITSAppUsesNonExemptEncryption": .boolean(false),
                // The same three keys the phone needs to find and reach a robot on the LAN.
                "NSLocalNetworkUsageDescription": .string(
                    "Discovers and connects to your Reachy Mini robot on the local network."
                ),
                "NSBonjourServices": .array([
                    .string("_reachy-mini._tcp"),
                    .string("_http._tcp"),
                ]),
                "NSAppTransportSecurity": .dictionary([
                    "NSAllowsLocalNetworking": .boolean(true),
                ]),
                // Both profiles drive the robot (`GamepadTeleop`). There is deliberately no
                // `GCSupportsControllerUserInteraction`: with it a controller would also move
                // focus, and its left stick and B button are already the body's turn and the
                // reset. The Siri Remote moves focus; a controller drives.
                "GCSupportedGameControllers": .array([
                    .dictionary(["ProfileName": .string("ExtendedGamepad")]),
                    .dictionary(["ProfileName": .string("MicroGamepad")]),
                ]),
                "UILaunchScreen": .dictionary([:]),
                "UIUserInterfaceStyle": .string("Automatic"),
                "UIApplicationSceneManifest": .dictionary([
                    "UIApplicationSupportsMultipleScenes": .boolean(false),
                ]),
            ]),
            sources: ["ReachyTV/Sources/**"],
            dependencies: [
                .package(product: "ReachyDesign"),
                .package(product: "ReachyKit"),
                .package(product: "ReachyTeleop"),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "6.0",
            ])
        )
    }
}
