import ReachyDesign
import ReachyKit
import SwiftUI

/// What a wedged app slot actually is, and the one thing that ends it.
///
/// Worth spelling out because every reading available to the reader is wrong: the
/// caption says the app is stopping, the app is in fact already dead, and both
/// controls answer 400. What is left is the daemon holding a slot it clears only on
/// the last line of `stop_current_app`, past three unbounded awaits
/// (`apps/manager.py:355`).
///
/// **`POST /api/daemon/restart` is not the way out** — it restarts the motor
/// backend, while the slot is held by the FastAPI process above it
/// (`daemon/daemon.py:473-536`, whose own docstring says so). Restarting the robot's
/// software is, and this app already carries one: `RESTART_DAEMON` over Bluetooth,
/// which the robot runs as root from a systemd unit that survives the restart. So
/// this points at it rather than building a second way to do the same thing.
///
/// A type of its own rather than a `private var` on `AppDetailSheet`: that file was
/// already at its length limit, and this is prose about the daemon rather than
/// anything about the page around it.
struct WedgedAppNotice: View {
    /// Which transition ran out of time. The way out is the same either way; what
    /// happened is not.
    let state: RobotAppStatus.State

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(Self.situation(in: state))
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Restarting the robot's software releases it: Settings › Advanced › Recovery over Bluetooth, then RESTART_DAEMON."
                )
            )
        }
        .font(Typography.status)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // A region disable: each sentence is one key, so none of them can be split
    // across `+` without handing a translator two fragments to reorder.
    // swiftlint:disable line_length

    /// What has happened, in the words the state allows.
    ///
    /// **The two transitions leave the robot in different places**, which is why
    /// `RunningAppCaption.stuck(in:)` splits its phrase as well. Saying "already
    /// stopped" about a start that never finished is the opposite of what happened —
    /// nothing ran, so nothing stopped — and the caption directly above this reads
    /// "Stuck starting" while it did.
    ///
    /// A `String` rather than a `LocalizedStringResource` because a test asserts on
    /// it, which is the case project rule 9 allows `String(localized:)` for. No
    /// reference image can hold the claim: only the sheet renders it, and a reference
    /// certifies the layout rather than the sentence.
    static func situation(in state: RobotAppStatus.State) -> String {
        switch state {
        case .stopping:
            String(
                localized: .reachy(
                    "The app itself has already stopped. The robot's software is still holding its slot, and nothing on this page can make it let go."
                )
            )
        case .starting:
            String(
                localized: .reachy(
                    "The app never finished starting. The robot's software is still holding its slot, and nothing on this page can make it let go."
                )
            )
        // Unreachable — only those two states are timed — but spelled out rather
        // than defaulted, so a later timed state cannot inherit the wrong half of
        // the story. This wording claims nothing about the app.
        case .running, .done, .error, .unknown:
            String(
                localized: .reachy(
                    "The robot's software is still holding this app's slot, and nothing on this page can make it let go."
                )
            )
        }
    }

    // swiftlint:enable line_length
}
