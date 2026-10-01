import ReachyDesign
import ReachyKit
import SwiftUI

/// "Include pre-release versions", drawn by both update surfaces.
///
/// A view of its own because the two copies drifted: the settings card learned that
/// a daemon before 1.10.0 cannot take a beta (`RobotSession.refusesPreReleaseUpdates`),
/// while `DaemonUpdateScreen` — which only a daemon below 1.9.0 ever reaches — kept
/// offering one to every robot it was shown to (#153).
struct PreReleaseToggle: View {
    let session: RobotSession
    let model: SystemUpdateModel?
    @Binding var preRelease: Bool

    var body: some View {
        // Drawn off, not merely greyed out: the stored choice is app-wide, so a beta
        // picked for a newer robot would otherwise sit switched on over one that
        // cannot have it. The stored value is kept for the next robot, and the
        // session asks the stable question either way.
        Toggle(
            .reachy("Include pre-release versions"),
            isOn: session.refusesPreReleaseUpdates ? .constant(false) : $preRelease
        )
        .disabled((model?.isBusy ?? true) || session.refusesPreReleaseUpdates)
        .onChange(of: preRelease) { _, newValue in
            Task { await model?.check(preRelease: newValue) }
        }
    }

    /// Why the switch is off, for the footer of the section it sits in — and nothing
    /// where it is not.
    struct RefusalNote: View {
        let session: RobotSession

        var body: some View {
            if session.refusesPreReleaseUpdates {
                Text(.reachy(
                    // swiftlint:disable:next line_length
                    "Pre-release versions need daemon 1.10.0. An older robot finds the wrong version and refuses to install it."
                ))
            }
        }
    }
}
