import ReachyDesign
import ReachyKit
import SwiftUI

/// The permissions this app asks for, and how each one reads on screen.
///
/// A presentation type, so it lives here and not in `ReachyKit`: a caller maps its own
/// domain value onto words and a tone, never the other way round — the same reason
/// `DaemonStateCaption` and `RunningAppCaption` sit beside their screens.
///
/// There is no camera row. The robot's camera arrives over WebRTC and this app never
/// opens a local one — `Apps/Project.swift` does declare `NSCameraUsageDescription`,
/// but only because App Store validation (ITMS-90683) demands one for the capture
/// APIs the WebRTC binary merely references; no prompt can ever fire, so there is
/// nothing here to report.
///
/// Notifications are the fourth row and the odd one, because they are not a device
/// permission at all. They gate no hardware and block nothing: a refusal costs the
/// reader one message about a job that finished while they were somewhere else, and
/// every other thing this app does is unaffected. The row exists anyway, because the
/// alternative is a switch in Settings that silently does nothing — which is the
/// failure this whole screen was built to end. It is also the only row with no
/// matching usage string in `Apps/Project.swift`: the system writes that prompt's
/// text, not this app. It goes last so the three device permissions keep the order
/// they have always had.
enum PermissionKind: CaseIterable, Hashable, Sendable {
    case bluetooth
    case localNetwork
    case microphone
    case notifications

    var title: LocalizedStringResource {
        switch self {
        case .bluetooth: .reachy("Bluetooth")
        case .localNetwork: .reachy("Local network")
        case .microphone: .reachy("Microphone")
        case .notifications: .reachy("Notifications")
        }
    }

    /// What the feature stops doing without it — the usage strings in
    /// `Apps/Project.swift` rhyme with these in the system prompt.
    var why: LocalizedStringResource {
        switch self {
        case .bluetooth:
            .reachy("Sets up a new robot's Wi-Fi, and recovers one that has dropped off the network.")
        case .localNetwork:
            .reachy("Finds your robot on this Wi-Fi and talks to it. Without it the robot cannot be reached at all.")
        case .microphone:
            .reachy("Lets you talk to people near the robot through its speaker during a call.")
        case .notifications:
            // "In another app", not "when the app is closed". Nothing here survives
            // the process being unloaded, and the copy must not imply it does.
            .reachy("Tells you when an install or a robot update finishes while you're in another app.")
        }
    }

    var symbol: String {
        switch self {
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .localNetwork: "wifi"
        case .microphone: "mic"
        case .notifications: "bell"
        }
    }

    var pane: PrivacySettingsLink.Pane {
        switch self {
        case .bluetooth: .bluetooth
        case .localNetwork: .localNetwork
        case .microphone: .microphone
        case .notifications: .notifications
        }
    }

    /// Only a refusal is coloured. "Allowed" stays quiet — a column of green ticks
    /// beside three permissions that are simply working tells the reader nothing.
    func tone(_ state: PermissionState) -> StatusTone {
        state.isBlocking ? .failed : .idle
    }

    /// A resolved `String`, not a `LocalizedStringResource`: `ReachyStatusLabel` takes
    /// a `String`, because nothing in `ReachyDesign` renders a domain type.
    func caption(_ state: PermissionState) -> String {
        switch state {
        case .granted:
            String(localized: .reachy("Allowed"))
        case .denied:
            String(localized: .reachy("Not allowed"))
        case .restricted:
            String(localized: .reachy("Blocked by device policy"))
        case .undetermined:
            undeterminedCaption
        }
    }

    /// Local network is the odd one out, and honestly so. It has no status API, so
    /// "undetermined" there covers two different situations — never asked, and asked
    /// but nothing has proved the answer either way (see `LocalNetworkProbe`). A
    /// granted permission on a Wi-Fi with no robot on it lands here too, so the word
    /// has to be "unknown" rather than "not asked".
    ///
    /// Notifications sit with the two that have a real status API: `notificationSettings()`
    /// answers precisely, so there is nothing unknown about this one.
    private var undeterminedCaption: String {
        switch self {
        case .localNetwork: String(localized: .reachy("Not known yet"))
        case .bluetooth, .microphone, .notifications: String(localized: .reachy("Not asked yet"))
        }
    }

    /// `@MainActor` because it builds a `View`, and `View` carries that isolation in
    /// Swift 6; the two mappings above are plain values and stay off it.
    @MainActor
    func label(_ state: PermissionState) -> ReachyStatusLabel {
        ReachyStatusLabel(text: caption(state), tone: tone(state))
    }
}
