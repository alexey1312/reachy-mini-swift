import ReachyDesign
import ReachyKit
import SwiftUI

/// "Share anonymous usage data", the switch Pollen's desktop and mobile apps show
/// for daemon 1.13.0's telemetry.
///
/// The choice is the robot's, so it holds for every app that connects to it, and
/// the footer says so. Nothing is drawn until the robot has answered: see
/// ``RobotTelemetryModel``.
struct TelemetrySection: View {
    let session: RobotSession
    let model: RobotTelemetryModel

    var body: some View {
        if let status = model.status {
            Section {
                Toggle(.reachy("Share anonymous usage data"), isOn: sharing(status))
                    .disabled(status.isDisabledByEnvironment || model.isSaving)
                if let lastError = model.lastError {
                    Text(lastError)
                        .font(Typography.status)
                        .foregroundStyle(Tone.danger.style)
                }
            } header: {
                Text(.reachy("Usage data"))
            } footer: {
                if status.isDisabledByEnvironment {
                    Text(.reachy("A setting on the robot turns this off, so the robot sends nothing."))
                } else {
                    Text(
                        .reachy(
                            // swiftlint:disable:next line_length
                            "The robot tells Pollen Robotics which software and apps it runs, and where they fail. It never sends your account, your network, logs, the camera or audio. This choice belongs to the robot and applies to every app."
                        )
                    )
                }
            }
        }
    }

    /// Off while a variable on the robot holds it off, whatever the stored choice:
    /// the switch says what the robot does.
    private func sharing(_ status: RobotTelemetry) -> Binding<Bool> {
        Binding(
            get: { status.isSharing },
            set: { isOn in Task { await model.setSharing(isOn, session: session) } }
        )
    }
}
