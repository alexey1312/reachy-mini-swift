import ReachyDesign
import ReachyKit
import SwiftUI

/// Why there is no conversation to show, said specifically.
///
/// The shape `AppsUnavailableView` established, and for the reason its doc gives: a
/// generic "nothing here" sends people chasing a problem they do not have, and an action
/// that leads back to the state they are already in is worse than none.
///
/// The sentences are exposed as `String` so a test can assert them — a recorded image
/// certifies the layout and never the wording, which is the `WedgedAppNotice` precedent.
struct ConversationUnavailableView: View {
    let phase: ConversationModel.Phase
    /// Where the app's own settings live, when they can be reached at all. Nil over a
    /// relay session and for an app that is not running — the page is served by the app's
    /// own process, on the robot's own network.
    let settingsURL: URL?

    var body: some View {
        ContentUnavailableView {
            Label(Self.title(for: phase), systemImage: Self.symbol(for: phase))
        } description: {
            Text(Self.message(for: phase))
        } actions: {
            if case .backendUnconfigured = phase, let settingsURL {
                Link(destination: settingsURL) {
                    Text(.reachy("Open the app's settings"))
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    static func title(for phase: ConversationModel.Phase) -> String {
        switch phase {
        case .preparing:
            String(localized: .reachy("Reachy is still waking up"))
        case .live:
            String(localized: .reachy("Nothing said yet"))
        case .interrupted:
            String(localized: .reachy("Lost the conversation"))
        case .backendUnconfigured:
            String(localized: .reachy("Reachy has no voice set up"))
        case let .unavailable(reason):
            switch reason {
            case .appStopped: String(localized: .reachy("The conversation app stopped"))
            case .appUnavailable: String(localized: .reachy("The conversation app is not answering"))
            case .methodMissing: String(localized: .reachy("This build has no conversation controls"))
            case .noTransport: String(localized: .reachy("This connection cannot carry the conversation"))
            }
        }
    }

    static func message(for phase: ConversationModel.Phase) -> String {
        switch phase {
        case .preparing:
            String(localized: .reachy("The voice backend can take up to a minute and a half to start."))
        case .live:
            // The one sentence this whole screen exists to be honest about.
            String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "Speak to Reachy, or type below. Anything said before this opened was not recorded — the robot keeps no transcript."
                )
            )
        case .interrupted:
            String(localized: .reachy("The feed stopped. Anything said since is lost — the robot keeps no history."))
        case .backendUnconfigured:
            String(localized: .reachy("Open the app's own settings on the robot to add a key."))
        case let .unavailable(reason):
            switch reason {
            case .appStopped:
                String(localized: .reachy("It was running when this opened. Start it again from the app's page."))
            case .appUnavailable:
                String(localized: .reachy("The app is installed and not responding. Restarting it may help."))
            case .methodMissing:
                String(localized: .reachy("Update the conversation app on the robot to control it from here."))
            case .noTransport:
                String(localized: .reachy("The robot's software is too old to relay the conversation."))
            }
        }
    }

    private static func symbol(for phase: ConversationModel.Phase) -> String {
        switch phase {
        case .preparing: "hourglass"
        case .live: "bubble.left.and.bubble.right"
        case .interrupted: "wifi.slash"
        case .backendUnconfigured: "key"
        case .unavailable: "bubble.left.and.bubble.right"
        }
    }
}
