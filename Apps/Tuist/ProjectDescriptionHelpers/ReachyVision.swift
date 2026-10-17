import ProjectDescription

public extension Target {
    /// Apple Vision Pro, native. A target of its own rather than a fourth destination
    /// of `ReachyMini`, because the two need different scene manifests: the headset's
    /// head tracking reads in an immersive space, which is a second scene, and
    /// `ReachyMini` declares one scene on purpose for its quick actions
    /// (`UIApplicationSupportsMultipleScenes` in `Apps/Project.swift`). The same bundle
    /// ID, so it is the same App Store app, and shipping it would replace the iPad app
    /// Apple Vision runs today in compatibility mode. No CI job builds it: the five
    /// macOS slots are spent (`docs/research/visionos.md`).
    static func reachyVision(appGroup: String) -> Target {
        .target(
            name: "ReachyVision",
            destinations: [.appleVision],
            product: .app,
            bundleId: "com.alexey1312.ReachyMini",
            deploymentTargets: .visionOS("26.0"),
            infoPlist: .extendingDefault(with: visionInfoPlist(appGroup: appGroup)),
            // `DeviceCheckView` belongs to ReachyMini, which an app target cannot
            // import; the storybook compiles the same two files in for the same reason.
            sources: [
                "ReachyVision/Sources/**",
                "ReachyMini/Sources/DeviceCheckView.swift",
                "ReachyMini/Sources/DeviceCheckModel.swift",
            ],
            dependencies: [
                .package(product: "ReachyDesign"),
                .package(product: "ReachyKit"),
                .package(product: "ReachyUI"),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "6.0",
                // The iPhone's: an App Group and the key-value store, nothing macOS-only.
                "CODE_SIGN_ENTITLEMENTS": "ReachyMini/Entitlements/ReachyMini-iOS.entitlements",
                // LiveKit's visionOS simulator slice is arm64 alone, and so is every Mac
                // that runs a visionOS simulator, so a generic build links no Intel slice.
                "EXCLUDED_ARCHS[sdk=xrsimulator*]": "x86_64",
            ])
        )
    }
}

/// The visionOS app's keys: the iPhone app's network, Bluetooth and microphone
/// strings, a scene manifest of its own, and none of the iPhone's call, quick action
/// or Live Activity keys.
private func visionInfoPlist(appGroup: String) -> [String: Plist.Value] {
    [
        "CFBundleDisplayName": .string("Hey Reachy"),
        "CFBundleName": .string("Hey Reachy"),
        "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
        "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
        // ITMS-90683, as for the iPhone: the WebRTC framework references the capture
        // APIs, and the app never records with the headset's cameras.
        "NSCameraUsageDescription": .string(
            "Hey Reachy never records with your camera; the robot video stack references this API."
        ),
        "ITSAppUsesNonExemptEncryption": .boolean(false),
        "LSApplicationCategoryType": .string("public.app-category.utilities"),
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
        "NSBluetoothAlwaysUsageDescription": .string(
            "Sets up your Reachy Mini's Wi-Fi and recovers a robot that can't reach the network."
        ),
        "NSMicrophoneUsageDescription": .string(
            "Talk to people near your Reachy Mini through its speaker."
        ),
        // No `NSMotionUsageDescription` and no world-sensing string: the headset's
        // pose comes from `queryDeviceAnchor`, which needs neither.
        "UIBackgroundModes": .array([.string("audio")]),
        // True, unlike the iPhone's: an immersive space is a second scene, and
        // without this key `openImmersiveSpace` is refused.
        "UIApplicationSceneManifest": .dictionary([
            "UIApplicationSupportsMultipleScenes": .boolean(true),
            "UIApplicationPreferredDefaultSceneSessionRole": .string("UIWindowSceneSessionRoleApplication"),
        ]),
        "ReachyAppGroupIdentifier": .string(appGroup),
        // The OAuth callback's scheme, which the Hugging Face sign-in needs here too.
        "CFBundleURLTypes": .array([
            .dictionary([
                "CFBundleURLName": .string("com.alexey1312.ReachyMini"),
                "CFBundleURLSchemes": .array([.string("reachy-mini-swift")]),
            ]),
        ]),
        "NSUserActivityTypes": .array([
            .string("com.apple.corespotlightitem"),
            .string("com.alexey1312.ReachyMini.session"),
        ]),
    ]
}
