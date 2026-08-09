import ProjectDescription

/// The app and its widget extension are separate processes with separate
/// containers, so anything both must read — the known robots, the snapshot the
/// widget renders — lives in this group rather than in either container.
let appGroup = "group.com.alexey1312.ReachyMini"

let project = Project(
    name: "ReachyMiniApps",
    packages: [
        // Local ReachyKit SPM package at the repo root
        .package(path: ".."),
        // Prefire renders SwiftUI previews as snapshots and as a browsable playbook. It is
        // declared here rather than in Package.swift because its generated tests and its
        // PlaybookView both call UIKit unconditionally — the root package still builds for macOS.
        // Exact, not `upToNextMajor`: `ReachyUISnapshotTests/PreviewTests.stencil` is a fork of
        // this version's built-in test template, and a floated minor would render it against a
        // changed set of Stencil arguments.
        .remote(url: "https://github.com/BarredEwe/Prefire", requirement: .exact("5.7.0")),
        .remote(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            requirement: .upToNextMajor(from: "1.19.4")
        ),
    ],
    settings: .settings(
        // One version for the app and the widget: App Store validation requires
        // the extension's CFBundleShortVersionString to match its host's.
        base: [
            "MARKETING_VERSION": "1.0.0",
            "CURRENT_PROJECT_VERSION": "1",
        ],
        configurations: [
            // Set project-wide rather than per target: the previews and the playbook reach ReachyUI's
            // internal screens through `@testable import`, and it is the *package* target that has to
            // be built with testability for that to link.
            .debug(name: .debug, settings: ["ENABLE_TESTABILITY": "YES"]),
            .release(name: .release),
        ]
    ),
    targets: [
        .target(
            name: "ReachyMini",
            destinations: [.iPhone, .iPad, .mac],
            product: .app,
            bundleId: "com.alexey1312.ReachyMini",
            deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
            infoPlist: .extendingDefault(with: [
                // The product name is the internal identifier; this is the brand.
                "CFBundleDisplayName": .string("Hey Reachy"),
                "CFBundleName": .string("Hey Reachy"),
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                // HTTPS-exempt encryption only; answered here once so App Store
                // Connect never asks per build.
                "ITSAppUsesNonExemptEncryption": .boolean(false),
                "LSApplicationCategoryType": .string("public.app-category.utilities"),
                // Phase 0.4 device checks: Local Network permission + Bonjour + ATS
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
                // BLE Wi-Fi provisioning. The only key a foreground central needs on
                // iOS 18: no capability, and no pairing prompt either, since the robot
                // registers a NoInputNoOutput Just-Works agent.
                // NSBluetoothPeripheralUsageDescription is iOS 12 and earlier — omitted.
                "NSBluetoothAlwaysUsageDescription": .string(
                    "Sets up your Reachy Mini's Wi-Fi and recovers a robot that can't reach the network."
                ),
                // Phase 2 camera: WebRTC mic uplink (client mic → robot speaker)
                "NSMicrophoneUsageDescription": .string(
                    "Talk to people near your Reachy Mini through its speaker."
                ),
                "UILaunchScreen": .dictionary([:]),
                // Read by `KnownRobots`, which is in a library and so cannot know
                // one developer account's group. The extension declares the same.
                "ReachyAppGroupIdentifier": .string(appGroup),
                // The widget opens the app through this scheme. It is the one the
                // OAuth callback already uses: an app gets a scheme, and
                // `ASWebAuthenticationSession` claims the callback while a sign-in
                // is running regardless of what is registered here.
                "CFBundleURLTypes": .array([
                    .dictionary([
                        "CFBundleURLName": .string("com.alexey1312.ReachyMini"),
                        "CFBundleURLSchemes": .array([.string("reachy-mini-swift")]),
                    ]),
                ]),
            ]),
            sources: ["ReachyMini/Sources/**"],
            resources: ["ReachyMini/Resources/**"],
            dependencies: [
                .package(product: "ReachyKit"),
                .package(product: "ReachyUI"),
                // The intents live there so the widget extension can reach the same
                // ones; the shortcuts provider that exposes them to Siri has to be
                // in this bundle.
                .package(product: "ReachyWidgetUI"),
                // iOS only, and conditional so the macOS build of this app does not
                // try to embed an extension that has no macOS destination.
                .target(name: "ReachyWidget", condition: .when([.ios])),
            ],
            // Two files rather than one generated dictionary: the macOS build is
            // sandboxed and hardened for Developer ID, and those keys are
            // macOS-only — signing an iOS build with them fails against any
            // provisioning profile. The `[sdk=macosx*]` override picks per SDK.
            settings: .settings(base: [
                "SWIFT_VERSION": "6.0",
                "CODE_SIGN_ENTITLEMENTS": "ReachyMini/Entitlements/ReachyMini-iOS.entitlements",
                "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "ReachyMini/Entitlements/ReachyMini-macOS.entitlements",
            ])
        ),
        // Deliberately thin: a timeline provider over the shared snapshot and a
        // view. It depends on ReachyWidgetUI rather than ReachyUI so that a
        // process woken for a moment does not link WebRTC and RealityKit.
        .target(
            name: "ReachyWidget",
            destinations: [.iPhone, .iPad],
            product: .appExtension,
            bundleId: "com.alexey1312.ReachyMini.Widget",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": .string("Hey Reachy"),
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                "ITSAppUsesNonExemptEncryption": .boolean(false),
                // Its own process, so it needs its own copy of the group name.
                "ReachyAppGroupIdentifier": .string(appGroup),
                // The control buttons run their intent in *this* process, and it
                // talks to the robot over plain HTTP on the LAN. Without the ATS
                // exception that request is refused before it leaves the device;
                // the usage string is what the system would show if it ever had a
                // screen to ask from, which an extension does not — so the
                // permission has to already exist from the app having connected.
                "NSLocalNetworkUsageDescription": .string(
                    "Wakes your Reachy Mini and starts its apps on the local network."
                ),
                "NSBonjourServices": .array([
                    .string("_reachy-mini._tcp"),
                    .string("_http._tcp"),
                ]),
                "NSAppTransportSecurity": .dictionary([
                    "NSAllowsLocalNetworking": .boolean(true),
                ]),
                "NSExtension": .dictionary([
                    "NSExtensionPointIdentifier": .string("com.apple.widgetkit-extension"),
                ]),
            ]),
            sources: ["ReachyWidget/Sources/**"],
            entitlements: .dictionary([
                "com.apple.security.application-groups": .array([.string(appGroup)]),
            ]),
            dependencies: [
                .package(product: "ReachyKit"),
                .package(product: "ReachyWidgetUI"),
                // Declared even though `ReachyWidgetUI` already links it: Swift needs a
                // direct dependency to `import` a module, and this target's controls name
                // their titles with `.reachy(_:)`.
                .package(product: "ReachyDesign"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "6.0"])
        ),
        .target(
            name: "ReachyStorybook",
            destinations: [.iPhone, .iPad],
            product: .app,
            bundleId: "com.alexey1312.ReachyMiniStorybook",
            deploymentTargets: .multiplatform(iOS: "18.0"),
            infoPlist: .extendingDefault(with: [
                // No Bonjour or ATS keys: the storybook renders fixtures and never reaches the network.
                "UILaunchScreen": .dictionary([:]),
            ]),
            // `PrefirePlaybookPlugin` is deliberately absent: it only ever scans the sources of
            // the target it is attached to (`GeneratePlaybookCommand` ignores the config's
            // `sources`, and `playbook_configuration` has no such key), so it cannot see the
            // previews that live in ReachyUI. `mise run storybook` runs the CLI instead.
            // `DeviceCheckView` belongs to ReachyMini, which an app target cannot import; its two
            // source files are compiled in directly so the catalogue can show that screen too.
            sources: [
                "ReachyStorybook/Sources/**",
                "ReachyStorybook/Generated/**",
                "../Sources/ReachyDesign/Previews/**",
                "../Sources/ReachyUI/Previews/**",
                "../Sources/ReachyWidgetUI/Previews/**",
                "ReachyMini/Sources/DeviceCheckView.swift",
                "ReachyMini/Sources/DeviceCheckModel.swift",
                "ReachyMini/Previews/**",
            ],
            dependencies: [
                .package(product: "ReachyDesign"),
                .package(product: "ReachyUI"),
                .package(product: "ReachyWidgetUI"),
                .package(product: "Prefire"),
            ]
        ),
        .target(
            name: "ReachyUISnapshotTests",
            destinations: [.iPhone, .iPad],
            product: .unitTests,
            bundleId: "com.alexey1312.ReachyUISnapshotTests",
            deploymentTargets: .multiplatform(iOS: "18.0"),
            sources: [
                "ReachyUISnapshotTests/Sources/**",
                "../Sources/ReachyDesign/Previews/**",
                "../Sources/ReachyUI/Previews/**",
                "../Sources/ReachyWidgetUI/Previews/**",
                "ReachyMini/Sources/DeviceCheckView.swift",
                "ReachyMini/Sources/DeviceCheckModel.swift",
                "ReachyMini/Previews/**",
            ],
            dependencies: [
                .package(product: "ReachyDesign"),
                .package(product: "ReachyUI"),
                .package(product: "ReachyWidgetUI"),
                .package(product: "Prefire"),
                .package(product: "SnapshotTesting"),
                .package(product: "PrefireTestsPlugin", type: .plugin),
            ]
        ),
    ]
)
