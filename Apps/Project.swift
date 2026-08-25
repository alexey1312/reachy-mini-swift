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
            // Beta: the first tag is 0.1.0, and the tag and the shipped version
            // have to be the same number to be worth reading.
            "MARKETING_VERSION": "0.4.1",
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
                // What `\(.applicationName)` in `ReachyShortcuts` resolves to, and
                // the display name alone reads badly inside a phrase: "Wake up Hey
                // Reachy". Siri matches every phrase against these as well.
                // Deliberately not "Reachy Mini" — that is the name of Pollen's own
                // app, and on a phone carrying both it would be ambiguous.
                // **Siri only, and it is not a Spotlight key** — QA1950 describes it
                // as the spoken form and says nothing about typed search, so adding
                // a word here does nothing for a query in the search field. That
                // half is `Navigation/SpotlightIndex.swift`. Apple's own note there:
                // put synonyms in it, never the display name itself.
                "INAlternativeAppNames": .array([
                    .dictionary(["INAlternativeAppName": .string("Reachy")]),
                ]),
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                // Spelled out because `actool` does not write it: it fills
                // CFBundleIcons from the catalogue and leaves the top level
                // empty, which App Store Connect rejects the upload over. Found
                // by unpacking the exported .ipa, not by any build warning.
                "CFBundleIconName": .string("AppIcon"),
                // ITMS-90683: WebRTC (and RealityKit via ARKit) reference the
                // capture APIs, so the string is required even though the app
                // never records with the phone's camera. Say exactly that.
                "NSCameraUsageDescription": .string(
                    "Hey Reachy never records with your phone's camera; the robot video stack references this API."
                ),
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
                // The UIScene lifecycle is a launch requirement under the iOS 27
                // SDK, and SwiftUI's `App` being scene-based is not the same as
                // this app *declaring* it — Tuist's `.extendingDefault` does not
                // supply the manifest, so nothing here said so.
                //
                // **No `UISceneConfigurations`, deliberately.** The one scene is
                // configured in code: `QuickActionAppDelegate` answers
                // `configurationForConnecting` with a `UISceneConfiguration(name:
                // nil, …)` naming `QuickActionSceneDelegate`, which is the only way
                // to be told a Home Screen quick action was tapped. Listing a
                // configuration here would give UIKit a second, disagreeing answer
                // about the delegate class; declaring adoption and leaving the
                // configuration to the delegate is the combination Apple documents
                // for an app that builds its own.
                "UIApplicationSceneManifest": .dictionary([
                    "UIApplicationSupportsMultipleScenes": .boolean(false),
                ]),
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
                // The literal value of `CSSearchableItemActionType`, which is how a
                // tapped Spotlight row reaches `RootLifecycle`. Sources disagree
                // about whether a *system* activity type has to be declared here at
                // all — a custom one certainly does — and the failure mode if it
                // does is silent: the rows are found, the tap opens the app, and it
                // lands on whatever tab was last selected. Declaring it costs one
                // line and settles the question. `Navigation/SpotlightIndex.swift`.
                "NSUserActivityTypes": .array([
                    .string("com.apple.corespotlightitem"),
                    // `ReachyHandoff.activityType` — the session Handoff between
                    // devices. The pair can drift and no test can see it; the
                    // symptom is a Handoff badge that never appears.
                    .string("com.alexey1312.ReachyMini.session"),
                ]),
            ]),
            sources: ["ReachyMini/Sources/**"],
            // The five themed icons are iOS-only inputs. macOS has no alternate
            // icons at all, so its `actool` compiles them and then drops them —
            // measured: the macOS `Assets.car` carries `AppIcon` and nothing else.
            // Scoping them saves that work. It is **not** what fixed the macOS asset
            // compilation on CI — that needed a newer Xcode, and `ci.yml` says which.
            resources: [
                .glob(
                    pattern: "ReachyMini/Resources/**",
                    excluding: ["ReachyMini/Resources/AppIcon-*.icon"]
                ),
                .glob(
                    pattern: "ReachyMini/Resources/AppIcon-*.icon",
                    inclusionCondition: .when([.ios])
                ),
            ],
            dependencies: [
                .package(product: "ReachyKit"),
                .package(product: "ReachyUI"),
                // The intents live there so the widget extension can reach the same
                // ones; the shortcuts provider that exposes them to Siri has to be
                // in this bundle.
                .package(product: "ReachyWidgetUI"),
                // No longer conditional: the extension has a Mac destination, so the
                // macOS app embeds it and the Mac gets the two reading widgets.
                .target(name: "ReachyWidget"),
            ],
            // Two files rather than one generated dictionary: the macOS build is
            // sandboxed and hardened for Developer ID, and those keys are
            // macOS-only — signing an iOS build with them fails against any
            // provisioning profile. The `[sdk=macosx*]` override picks per SDK.
            settings: .settings(base: [
                "SWIFT_VERSION": "6.0",
                "CODE_SIGN_ENTITLEMENTS": "ReachyMini/Entitlements/ReachyMini-iOS.entitlements",
                "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "ReachyMini/Entitlements/ReachyMini-macOS.entitlements",
                // Notarization rejects a Developer ID app without it: the executable
                // signs with flags=0x0 and the notary answers "does not have the
                // hardened runtime enabled" per architecture.
                "ENABLE_HARDENED_RUNTIME[sdk=macosx*]": "YES",
                // SDK-scoped because macOS has no alternate icons: an unscoped
                // setting names five bundles the macOS build has no use for.
                // Every name here must equal a `ReachyTheme.alternateIconName`
                // and a committed `.icon` directory — `ThemeIconNameTests` reads
                // this literal back and fails when the three drift.
                "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES[sdk=iphone*]":
                    "AppIcon-Bronze AppIcon-Teal AppIcon-Indigo AppIcon-Orchid AppIcon-Rose",
                "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS[sdk=iphone*]": "YES",
            ])
        ),
        // Deliberately thin: a timeline provider over the shared snapshot and a
        // view. It depends on ReachyWidgetUI rather than ReachyUI so that a
        // process woken for a moment does not link WebRTC and RealityKit.
        .target(
            name: "ReachyWidget",
            destinations: [.iPhone, .iPad, .mac],
            product: .appExtension,
            bundleId: "com.alexey1312.ReachyMini.Widget",
            deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
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
            dependencies: [
                .package(product: "ReachyKit"),
                .package(product: "ReachyWidgetUI"),
                // Declared even though `ReachyWidgetUI` already links it: Swift needs a
                // direct dependency to `import` a module, and this target's controls name
                // their titles with `.reachy(_:)`.
                .package(product: "ReachyDesign"),
            ],
            // Two files rather than the one generated dictionary this used to carry,
            // for the reason the app target states: a macOS app extension must be
            // sandboxed, and `com.apple.security.app-sandbox` is a macOS-only key
            // that fails an iOS build against any provisioning profile.
            settings: .settings(base: [
                "SWIFT_VERSION": "6.0",
                "CODE_SIGN_ENTITLEMENTS": "ReachyWidget/Entitlements/ReachyWidget-iOS.entitlements",
                "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]":
                    "ReachyWidget/Entitlements/ReachyWidget-macOS.entitlements",
                // The notary reads every executable in the bundle, not only the app's,
                // so an extension needs this as much as its host — see the app target.
                "ENABLE_HARDENED_RUNTIME[sdk=macosx*]": "YES",
            ])
        ),
        // Smoke tests: the one thing snapshots cannot see is the app binary itself
        // booting. iOS-only — XCUITest on macOS needs Accessibility permission on
        // the runner, which CI cannot grant.
        .target(
            name: "ReachyMiniUITests",
            destinations: [.iPhone, .iPad],
            product: .uiTests,
            bundleId: "com.alexey1312.ReachyMiniUITests",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .default,
            sources: ["ReachyMiniUITests/Sources/**"],
            dependencies: [
                .target(name: "ReachyMini"),
            ]
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
