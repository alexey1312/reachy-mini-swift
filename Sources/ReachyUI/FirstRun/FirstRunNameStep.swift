import ReachyDesign
import ReachyKit
import SwiftUI

/// Names the robot over the session, which over the relay is `set_robot_name`.
///
/// Prefilled with the name the robot already has, so keeping it is one tap and costs
/// the robot nothing (`FirstRunModel.saveName`). A failure stays on the step with the
/// reason under the field; Skip is always there.
struct FirstRunNameStep: View {
    let model: FirstRunModel

    var body: some View {
        let field = RobotNameField(
            supportsRename: model.session.supportsRename,
            daemonVersion: model.session.connectedIdentity?.daemonVersion
        )
        OnboardingStepScaffold(
            title: String(localized: .reachy("Name your robot")),
            message: String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "The name shows in this app, on your network and for remote access. You can change it later in Settings."
                )
            )
        ) {
            Section {
                TextField(.reachy("Name"), text: Binding(get: { model.nameInput }, set: { model.nameInput = $0 }))
                    .autocorrectionDisabled()
                    .onSubmit(submit)
                    .disabled(!field.isEditable || model.isSavingName)
            } footer: {
                if model.nameIsTooLong {
                    Text(.reachy("A name can be up to 64 characters long."))
                        .foregroundStyle(Tone.warning.style)
                } else if !field.isEditable {
                    Text(field.footer)
                }
            }
            if let message = model.nameError {
                Section {
                    ReachyErrorRow(message)
                }
            }
        } actions: {
            if field.isEditable {
                ReachyActionButton(.reachy("Use this name"), fullWidth: true) {
                    submit()
                }
                .disabled(!model.canSaveName)
                FirstRunSkipButton(model: model)
                    .disabled(model.isSavingName)
            } else {
                ReachyActionButton(.reachy("Continue"), fullWidth: true) {
                    model.advance()
                }
            }
        }
    }

    private func submit() {
        guard model.canSaveName else { return }
        Task { await model.saveName() }
    }
}
