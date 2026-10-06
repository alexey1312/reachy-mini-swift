import ReachyDesign
import ReachyKit
import SwiftUI

/// Explains why motion controls are inert and offers the one action that fixes
/// it. Silently disabling them reads as a broken screen — the daemon answers
/// motion commands from an asleep robot without moving anything.
struct AsleepBanner: View {
    let session: RobotSession

    var body: some View {
        // Wake up goes under the text, not beside it. Beside it, the button and a
        // spacer shared the width the text did not take, so the text column kept
        // about 155 pt in a form row on a phone and "Motors and camera are off"
        // broke over two lines with 53 pt of empty row beside it. Under the text,
        // the sentence has the whole row at every text size.
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(Tone.warning.style)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title)
                        .font(Typography.detail.weight(.medium))
                    Text(detail)
                        .font(Typography.status)
                        .foregroundStyle(.secondary)
                }
                if session.powerTransition != nil {
                    ProgressView()
                } else {
                    ReachyActionButton(.reachy("Wake up")) {
                        Task { await session.wake() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String {
        session
            .isBackendRunning ? String(localized: .reachy("Robot is asleep")) :
            String(localized: .reachy("Motors and camera are off"))
    }

    private var detail: String {
        session.isBackendRunning
            ? String(localized: .reachy("The motors are off, so the robot accepts commands without moving."))
            : String(localized: .reachy("The live view and the controls come back once they start."))
    }
}
