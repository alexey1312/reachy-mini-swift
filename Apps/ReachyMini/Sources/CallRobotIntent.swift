import AppIntents
import ReachyUI
import ReachyWidgetUI

/// "Call Reachy" — opens the robot's camera and unmutes the microphone, which
/// is what a call to a telepresence robot *is* (issue #78). The heavy lifting
/// is `RootCallLifecycle`'s: this intent only posts into `CallRequestInbox`,
/// the way a Recents redial does, so both entry points walk one path.
///
/// **In the app target, and it must stay here.** Every other intent lives in
/// `ReachyWidgetUI` so the widget extension can reach it — but this one opens
/// the app, and `openAppWhenRun` errors at runtime when an intent runs in an
/// appex (the `WakeRobotIntent` comment carries the details; `supportedModes`
/// is the iOS 26 replacement and this app deploys to 18). Living here keeps it
/// out of the extension's `Metadata.appintents` entirely. It is the first
/// intent extracted from the app target's own sources —
/// `Scripts/check-appintents-metadata.sh` counts it in `REQUIRED_APP_ACTIONS`.
///
/// Cross-platform deliberately, though LiveCommunicationKit is not: that script
/// checks the **macOS** app bundle too, so an `#if os(iOS)` here would fail the
/// macOS release build. On macOS the request routes identically — Live tab,
/// camera, microphone on — just without the system call framing around it,
/// which is honest behavior rather than a stub.
struct CallRobotIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Reachy Mini"
    static let description = IntentDescription(
        "Opens the robot's camera and unmutes your microphone so you can talk through its speaker."
    )
    static let openAppWhenRun = true

    /// Optional like every robot parameter here: unfilled is "the connected
    /// robot", which is what keeps the bare Siri phrase working.
    @Parameter(title: "Robot")
    var robot: RobotEntity?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // An identity, never an address (rule 4) — and checked now so a robot
        // this app has since forgotten fails with words rather than opening the
        // app onto a request that can never route.
        guard robot == nil || RobotIntentTarget.knownRobot(id: robot?.id) != nil else {
            throw RobotIntentError.noKnownRobot
        }
        CallRequestInbox.shared.receive(robotID: robot?.id)
        return .result()
    }
}
