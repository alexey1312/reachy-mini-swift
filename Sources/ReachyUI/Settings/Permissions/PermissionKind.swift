import ReachyDesign
import ReachyKit
import SwiftUI

/// The three device permissions this app asks for, and how each one reads on screen.
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
enum PermissionKind: CaseIterable, Hashable, Sendable {
    case bluetooth
    case localNetwork
    case microphone

    var title: LocalizedStringResource {
        switch self {
        case .bluetooth: .reachy("Bluetooth")
        case .localNetwork: .reachy("Local network")
        case .microphone: .reachy("Microphone")
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
        }
    }

    var symbol: String {
        switch self {
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .localNetwork: "wifi"
        case .microphone: "mic"
        }
    }

    var pane: PrivacySettingsLink.Pane {
        switch self {
        case .bluetooth: .bluetooth
        case .localNetwork: .localNetwork
        case .microphone: .microphone
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
    private var undeterminedCaption: String {
        switch self {
        case .localNetwork: String(localized: .reachy("Not known yet"))
        case .bluetooth, .microphone: String(localized: .reachy("Not asked yet"))
        }
    }

    /// `@MainActor` because it builds a `View`, and `View` carries that isolation in
    /// Swift 6; the two mappings above are plain values and stay off it.
    @MainActor
    func label(_ state: PermissionState) -> ReachyStatusLabel {
        ReachyStatusLabel(text: caption(state), tone: tone(state))
    }
}
