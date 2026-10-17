import ReachyDesign
import ReachyKit
import SwiftUI

/// One connected robot: its name and address, whether it is awake, and the three
/// things the TV does with it — wake or sleep it, drive it, let it go.
///
/// The address is on screen because a robot can answer at several, and which one is in
/// use is the first question when something goes wrong (`.claude/rules/networking.md`).
struct TVRobotScreen: View {
    let session: RobotSession
    @State private var isDriving = false

    var body: some View {
        HStack(alignment: .top, spacing: TVMetrics.gutter) {
            VStack(alignment: .leading, spacing: TVMetrics.group) {
                Text(verbatim: robotName)
                    .font(Typography.screenTitle.bold())
                if let address = session.address {
                    Text(verbatim: address.displayString)
                        .font(Typography.subtitle)
                        .foregroundStyle(.secondary)
                }
                state
                    .font(Typography.rowTitle)
                if let error = session.robotError {
                    // The session's own sentence about connection or power.
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: TVMetrics.group) {
                powerButton
                Button {
                    isDriving = true
                } label: {
                    Label(.reachy("Drive"), systemImage: "gamecontroller")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!canDrive)
                Button {
                    session.disconnect()
                } label: {
                    Label(.reachy("Disconnect"), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: TVMetrics.listWidth / 2, alignment: .leading)
        }
        .padding(TVMetrics.gutter)
        .fullScreenCover(isPresented: $isDriving) {
            TVDriveScreen(session: session)
        }
    }

    private var robotName: String {
        switch session.phase {
        case let .connected(identity), let .unreachable(identity):
            identity.name ?? session.address?.displayString ?? Bundle.main.displayName
        case .idle, .connecting:
            Bundle.main.displayName
        }
    }

    private var isUnreachable: Bool {
        if case .unreachable = session.phase {
            true
        } else {
            false
        }
    }

    /// A wake can take ninety seconds when it has to start the backend first, so the
    /// drive button waits for it rather than offering a robot that cannot move yet.
    private var canDrive: Bool {
        session.isAwake && session.powerTransition == nil && !isUnreachable
    }

    @ViewBuilder
    private var state: some View {
        if isUnreachable {
            Label(.reachy("Robot unreachable"), systemImage: "wifi.exclamationmark")
        } else if let transition = session.powerTransition {
            Label {
                Text(caption(for: transition))
            } icon: {
                ProgressView()
            }
        } else if !session.isBackendRunning {
            Label(.reachy("Motors and camera are off"), systemImage: "power")
        } else if session.isAwake {
            Label(.reachy("Awake"), systemImage: "sun.max")
        } else {
            Label(.reachy("Asleep"), systemImage: "moon.zzz")
        }
    }

    /// `.stoppingBackend` is set only by `powerOff()`, which the TV does not offer yet;
    /// it is spelled out because the switch is exhaustive, in the phone's words.
    private func caption(for transition: RobotSession.PowerTransition) -> LocalizedStringResource {
        switch transition {
        case .wakingUp: .reachy("Waking up…")
        case .goingToSleep: .reachy("Going to sleep…")
        case .startingBackend: .reachy("Starting the motors and camera… this can take a minute")
        case .stoppingBackend: .reachy("Powering off… going to sleep first")
        }
    }

    /// `wake()` starts a stopped backend itself, so one button covers both rungs.
    @ViewBuilder
    private var powerButton: some View {
        if session.isAwake {
            Button {
                Task { await session.sleep() }
            } label: {
                Label(.reachy("Go to sleep"), systemImage: "moon.zzz")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(session.powerTransition != nil || isUnreachable)
        } else {
            Button {
                Task { await session.wake() }
            } label: {
                Label(.reachy("Wake up"), systemImage: "sun.max")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(session.powerTransition != nil || isUnreachable)
        }
    }
}
