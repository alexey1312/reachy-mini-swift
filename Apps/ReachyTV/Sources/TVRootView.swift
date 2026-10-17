import ReachyKit
import SwiftUI

/// The connect screen until a robot answers, the robot screen after.
///
/// `.unreachable` belongs to the robot screen, as it does on the phone: a network blip
/// must not throw the reader back to the list while the session reconnects on its own.
struct TVRootView: View {
    let session: RobotSession

    var body: some View {
        switch session.phase {
        case .connected, .unreachable:
            TVRobotScreen(session: session)
        case .idle, .connecting:
            TVConnectScreen(session: session)
        }
    }
}

/// Sizes for a screen read from across a room. One-off values for this app alone, so
/// they stay here rather than in ReachyDesign (project rule 10); the phone's `Space`
/// rhythm is sized for a hand-held screen.
enum TVMetrics {
    /// Between the halves of a screen and around its content.
    static let gutter: CGFloat = 80
    /// Between the groups inside one half.
    static let group: CGFloat = 40
    /// The connect screen's list column.
    static let listWidth: CGFloat = 900
}

extension Bundle {
    /// The app's name as the Home Screen shows it. Read rather than written down, so the
    /// one spelling stays in `Apps/Project.swift` — the phone's Spotlight index does
    /// the same.
    var displayName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
    }
}
