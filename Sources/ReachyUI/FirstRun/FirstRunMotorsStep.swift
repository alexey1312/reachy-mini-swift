import ReachyDesign
import ReachyKit
import SwiftUI

/// The robot's first movement, and the check that comes before it.
///
/// Asleep, the twin shows the robot lying limp and `SleepPosition` names any motor
/// that is not where `goto_sleep` would have left it — including pairs that read each
/// other's positions, which is two cables in each other's sockets. Wake up stays
/// disabled until that passes, because a robot woken with two motors swapped drives
/// each to the other's target. Awake, the question is the owner's: did it move.
///
/// The twin's `RealityView` renders nothing headless, so the references cover the
/// words around it; `FirstRunModelTests` covers the gate.
struct FirstRunMotorsStep: View {
    let model: FirstRunModel

    @Environment(\.reachyPreviewMode) private var previewMode

    private var session: RobotSession {
        model.session
    }

    var body: some View {
        OnboardingStepScaffold(title: title, message: message) {
            if let twin = model.twin {
                Section {
                    SceneViewport(model: twin)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                }
            }
            status
            if let error = session.robotError {
                Section {
                    ReachyErrorRow(error)
                }
            }
        } actions: {
            actions
        }
        .task {
            guard !previewMode else { return }
            model.startTwin()
            await model.watchPose()
        }
        .onDisappear {
            guard !previewMode else { return }
            model.stopTwin()
        }
    }

    private var title: String {
        model.hasWoken
            ? String(localized: .reachy("Did it move?"))
            : String(localized: .reachy("Check the motors"))
    }

    private var message: String {
        model.hasWoken
            ? String(localized: .reachy("Your robot just stood up for the first time. Its picture here follows it."))
            : String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "Before it moves for the first time, check that every motor reads where it should. Lay the robot in its sleep position: head tilted down, antennas folded back."
                )
            )
    }

    @ViewBuilder
    private var status: some View {
        if model.hasWoken {
            if model.needsHelp {
                Section {
                    Label(
                        .reachy(
                            // swiftlint:disable:next line_length
                            "Check that the power supply is plugged in and switched on. You can wake the robot again from the Robot tab once setup is over."
                        ),
                        systemImage: "lightbulb"
                    )
                }
            }
        } else if session.isAwake {
            Section {
                Label(.reachy("Your robot is awake"), systemImage: "sun.max")
            } footer: {
                Text(.reachy("Put it to sleep so the check can see its resting position."))
            }
        } else {
            poseStatus
        }
    }

    @ViewBuilder
    private var poseStatus: some View {
        switch model.poseCheck {
        case .reading:
            Section {
                HStack(spacing: Space.sm) {
                    ProgressView()
                    Text(.reachy("Reading the motors…"))
                        .foregroundStyle(.secondary)
                }
            }
        case .checked(.inPosition):
            Section {
                Label(.reachy("Every motor is where it should be"), systemImage: "checkmark.circle")
                    .foregroundStyle(Tone.success.style)
            }
        case .checked(.unavailable):
            Section {
                Label(
                    .reachy("This robot does not report its motors one by one, so their position cannot be checked."),
                    systemImage: "info.circle"
                )
            }
        case let .checked(.outOfPosition(misplaced, swaps)):
            FirstRunMisplacedMotors(misplaced: misplaced, swaps: swaps)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.hasWoken {
            ReachyActionButton(.reachy("It moved"), fullWidth: true) {
                model.advance()
            }
            Button(.reachy("It didn't move")) { model.showHelp() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        } else if let transition = session.powerTransition {
            PowerTransitionRow(transition: transition)
        } else if session.isAwake {
            ReachyActionButton(.reachy("Put to sleep"), fullWidth: true) {
                Task { await model.putToSleep() }
            }
            FirstRunSkipButton(model: model)
        } else {
            ReachyActionButton(.reachy("Wake up"), fullWidth: true) {
                Task { await model.wakeUp() }
            }
            .disabled(!model.canWake)
            FirstRunSkipButton(model: model)
        }
    }
}

/// The motors the check names, and the pairs it suspects. A section of its own so the
/// step's switch stays one arm per state.
struct FirstRunMisplacedMotors: View {
    let misplaced: [RobotMotor]
    let swaps: [MotorSwap]

    var body: some View {
        Section {
            ForEach(misplaced, id: \.self) { motor in
                Label(RobotMotorCaption.name(motor), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.warning.style)
            }
        } header: {
            Text(.reachy("Not in place"))
        } footer: {
            Text(.reachy("The list follows the robot as you move it. Wake up comes back once every motor is in place."))
        }
        if !swaps.isEmpty {
            Section {
                ForEach(Array(swaps.enumerated()), id: \.offset) { _, swap in
                    HStack(spacing: Space.sm) {
                        Text(RobotMotorCaption.name(swap.first))
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(RobotMotorCaption.name(swap.second))
                    }
                }
            } header: {
                Text(.reachy("Possibly swapped"))
            } footer: {
                Text(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "These motors read each other's positions, which usually means their cables are in each other's sockets. Swap them back before waking the robot."
                    )
                )
            }
        }
    }
}

/// A motor's name as the owner would look for it on the robot.
enum RobotMotorCaption {
    static func name(_ motor: RobotMotor) -> String {
        switch motor {
        case .base: String(localized: .reachy("Body rotation"))
        case .neck1: String(localized: .reachy("Neck motor 1"))
        case .neck2: String(localized: .reachy("Neck motor 2"))
        case .neck3: String(localized: .reachy("Neck motor 3"))
        case .neck4: String(localized: .reachy("Neck motor 4"))
        case .neck5: String(localized: .reachy("Neck motor 5"))
        case .neck6: String(localized: .reachy("Neck motor 6"))
        case .rightAntenna: String(localized: .reachy("Right antenna"))
        case .leftAntenna: String(localized: .reachy("Left antenna"))
        }
    }
}
