import ReachyDesign
import SwiftUI

/// What the run is, before any of it touches the robot — and the way out for an owner
/// who set the robot up somewhere this app cannot see.
struct FirstRunWelcomeStep: View {
    let model: FirstRunModel

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("Let's wake it up together")),
            message: String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "This robot has never been woken up. A few short checks make sure it is put together right and can see, hear and speak. It takes about two minutes."
                )
            )
        ) {
            Section {
                check(String(localized: .reachy("Its name")), icon: "character.cursor.ibeam")
                check(String(localized: .reachy("Its motors")), icon: "gearshape.2")
                check(String(localized: .reachy("Its camera")), icon: "camera")
                check(String(localized: .reachy("Its microphones")), icon: "mic")
                check(String(localized: .reachy("Its speaker")), icon: "speaker.wave.2")
            } footer: {
                Label(
                    .reachy("Already set it up in another app? Skip setup, and it will not ask again."),
                    systemImage: "info.circle"
                )
            }
        } actions: {
            ReachyActionButton(.reachy("Start"), fullWidth: true) {
                model.advance()
            }
        }
    }

    private func check(_ title: String, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.tint)
        }
    }
}

/// The end of the run. Finishing is what writes the robot's flag and brings the shell.
struct FirstRunDoneStep: View {
    let model: FirstRunModel

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("All set")),
            message: String(
                localized: .reachy(
                    "Your robot is ready. The robot, its live view, moves, apps and settings are all in the tabs."
                )
            )
        ) {
            EmptyView()
        } actions: {
            ReachyActionButton(.reachy("Finish"), fullWidth: true) {
                Task { await model.finish() }
            }
        }
    }
}
