import ReachyDesign
import ReachyKit
import SwiftUI

/// Explains why motion controls are inert and offers the one action that fixes
/// it. Silently disabling them reads as a broken screen — the daemon answers
/// motion commands from an asleep robot without moving anything.
struct AsleepBanner: View {
    let session: RobotSession

    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(Tone.warning.style)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title)
                        .font(Typography.detail.weight(.medium))
                    Text(detail)
                        .font(Typography.status)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if session.powerTransition != nil {
                ProgressView()
            } else {
                ReachyActionButton(.reachy("Wake up")) {
                    Task { await session.wake() }
                }
            }
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
