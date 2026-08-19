import ReachyDesign
import ReachyKit
import SwiftUI

/// The strip under the Moves library: what the robot is doing about moves, and
/// the one control that changes it.
///
/// It is a phase rather than a button because two of the four states have no
/// control at all. Parking in particular has to be *shown*: it holds the daemon's
/// move slot for a second, so a screen that reported nothing there would claim
/// the robot was idle while it was still travelling — the same class of lie this
/// screen was fixed for.
struct MoveActivityBar: View {
    let activity: RobotSession.MoveActivity
    let stop: () -> Void

    var body: some View {
        VStack(spacing: Space.sm) {
            if let caption {
                Text(caption)
                    .font(Typography.status)
                    .foregroundStyle(.secondary)
            }
            if offersStop {
                stopButton
            }
        }
        .padding()
    }

    /// Absent for a move this app started: its own row already carries the
    /// animated `waveform`, and repeating the name under it says nothing new.
    private var caption: LocalizedStringResource? {
        switch activity {
        case let .playing(playback):
            // Adopted from `/api/move/running`, which names nothing. Saying so is
            // the honest answer — guessing at the dance would not be.
            playback.identity == nil ? .reachy("A move is running on the robot") : nil
        case .stopping:
            nil
        case .recentring:
            .reachy("Returning to neutral…")
        }
    }

    private var offersStop: Bool {
        switch activity {
        case .playing, .stopping: true
        // Nothing to stop: the robot is already on its way back, and cancelling
        // the parking would only leave it mid-pose.
        case .recentring: false
        }
    }

    private var stopButton: some View {
        Button(action: stop) {
            HStack(spacing: Space.sm) {
                if isStopping {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "stop.fill")
                }
                Text(isStopping ? .reachy("Stopping…") : .reachy("Stop"))
            }
            .frame(minWidth: 120)
        }
        .reachyButton(.prominent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Tone.danger.style)
        .disabled(isStopping)
    }

    private var isStopping: Bool {
        if case .stopping = activity {
            true
        } else {
            false
        }
    }
}
