#if os(iOS)
    import AppIntents
    import Foundation

    /// The Stop button on the Live Activity.
    ///
    /// **A fourth sibling rather than a conformance on `StopRobotAppIntent`.**
    /// `LiveActivityIntent` relocates execution into the *app's* process, and that one
    /// is a deliberate extension citizen: it runs under a 15 s budget, reaches the
    /// robot from the appex, and is the reason `ReachyWidget-macOS.entitlements` carries
    /// `com.apple.security.network.client`. Adding the conformance would move all four
    /// of its shipped callers at once. The repository already settles this shape —
    /// `RobotAppTileIntent`, `ToggleRobotAppIntent` and
    /// `RobotAppControlConfigurationIntent` do the same work and stay three types,
    /// because *where and how* an intent runs is part of its contract.
    ///
    /// Running in the app's process is strictly better for the network here: Local
    /// Network permission was granted to the app, and it already carries
    /// `NSLocalNetworkUsageDescription`, the Bonjour list and `NSAllowsLocalNetworking`.
    ///
    /// Plain `String` parameters and `isDiscoverable = false`, for the reason
    /// `RobotAppTileIntent` gives: a button that holds its intent in code must not
    /// depend on metadata extraction. It still *appears* in `Metadata.appintents` —
    /// `isDiscoverable` is recorded there as a flag, not as an absence — so it owes
    /// `Scripts/check-appintents-metadata.sh` an entry.
    ///
    /// **What it promises is that the request was sent, and no more.** The daemon sets
    /// `stopping` before any I/O and clears its slot only on the last line, past three
    /// unbounded awaits, so a 200 is not the app letting go. The card says "Stopping…"
    /// and the next reading is what corrects it.
    public struct StopRunningAppActivityIntent: LiveActivityIntent {
        public static let title: LocalizedStringResource = "Stop the app on your Reachy Mini"
        public static let description = IntentDescription(
            "Stops whatever app is holding the robot, from the Lock Screen."
        )
        public static let isDiscoverable = false

        @Parameter(title: "Robot") public var robot: String?

        public init() {}

        public init(robot: String?) {
            self.robot = robot
        }

        public func perform() async throws -> some IntentResult {
            // No `appID`: `RobotAppLaunchState` is keyed by app and "stop whatever is
            // running" names none — the same choice `StopRobotAppIntent` makes.
            try await RobotAppCommand(.stop, robot: robot).perform()
            return .result()
        }
    }
#endif
