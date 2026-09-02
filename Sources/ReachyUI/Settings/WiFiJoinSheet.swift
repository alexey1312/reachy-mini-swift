import ReachyDesign
import ReachyKit
import SwiftUI

/// Moves the robot to another network over the connection it is already on.
///
/// The Bluetooth flow exists for a robot this app cannot reach; this one is for a
/// robot it can, and the difference shows in two places. The scan is not squeezed
/// into one Bluetooth message, so the list is the whole list. And the join cannot be
/// watched: the robot answers, then takes the interface down under the answer.
struct WiFiJoinSheet: View {
    let session: RobotSession
    let onFinish: () -> Void

    @State private var model: WiFiJoinModel
    @Environment(\.reachyPreviewMode) private var previewMode

    init(session: RobotSession, model: WiFiJoinModel? = nil, onFinish: @escaping () -> Void) {
        self.session = session
        self.onFinish = onFinish
        _model = State(initialValue: model ?? WiFiJoinModel())
    }

    var body: some View {
        Form {
            switch model.phase {
            case .editing, .sending:
                editor
            case let .sent(ssid):
                sent(ssid)
            case let .refused(reason):
                refused(reason)
            case let .uncertain(ssid):
                uncertain(ssid)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(.reachy("Choose a network"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // Owned here rather than by the card that presents this, because the
                // policy is the sheet's: the send runs from a button action, not from
                // a `.task`, so dismissing does not cancel it. Left enabled it
                // finished against a model nobody was watching, while the robot may
                // already have been switching networks.
                Button(.reachy("Cancel")) { onFinish() }
                    .disabled(model.phase == .sending)
            }
        }
        .interactiveDismissDisabled(model.phase == .sending)
        .task {
            guard !previewMode else { return }
            await model.scan(session: session)
        }
    }

    @ViewBuilder
    private var editor: some View {
        Section {
            NetworkCredentialsFields(
                networks: model.networks,
                selected: $model.selected,
                manualSSID: $model.manualSSID,
                password: $model.password,
                isScanning: model.isScanning,
                scanFailure: model.scanFailure
            ) {
                Task { await model.scan(session: session) }
            }
        } header: {
            Text(.reachy("Network"))
        } footer: {
            Text(.reachy("The robot joins this network and then talks to this app over it."))
        }

        Section {
            TextField(.reachy("Code"), text: $model.code)
                .font(Typography.console)
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
        } header: {
            Text(.reachy("Enter the robot's code"))
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "The last five characters of the serial number printed on the robot. Capitals matter, and it is not always digits."
                )
            )
        }

        Section {
            Button(.reachy("Send to the robot")) {
                Task { await model.send(session: session) }
            }
            .disabled(!model.canSend)
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "The password is encrypted for this robot before it is sent. Sending it takes this link down: the robot switches networks and the app finds it again afterwards."
                )
            )
        }
        .overlay {
            if model.phase == .sending {
                ProgressView()
            }
        }
    }

    /// Nothing here waits on the robot, because nothing can: the link this screen ran
    /// over is the one the robot is taking down.
    private func sent(_ ssid: String) -> some View {
        Section {
            Label(.reachy("Switching to \(ssid)"), systemImage: "wifi")
                .foregroundStyle(Tone.success.style)
            Button(.reachy("Back to the robot list")) {
                session.disconnect()
                onFinish()
            }
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "The robot took the network and is moving to it now. A password it cannot use puts it back on the one it was on, so nothing here is lost either way."
                )
            )
        }
    }

    private func refused(_ reason: String) -> some View {
        Section {
            Text(reason)
                .font(Typography.status)
                .foregroundStyle(Tone.danger.style)
            Button(.reachy("Try again")) { model.editAgain() }
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "A wrong code is the usual reason. The robot counts them itself and starts making you wait, so there is nothing to do but try again more slowly."
                )
            )
        }
    }

    /// The link dropped before the robot answered — which is also what an accepted
    /// password does. So this offers the same way out as success rather than the
    /// retry a refusal offers: going back to look for the robot settles it, and
    /// retyping a password that worked does not.
    private func uncertain(_ ssid: String) -> some View {
        Section {
            Label(.reachy("Lost the robot while sending"), systemImage: "wifi.exclamationmark")
                .foregroundStyle(Tone.warning.style)
            Button(.reachy("Back to the robot list")) {
                session.disconnect()
                onFinish()
            }
            Button(.reachy("Try again")) { model.editAgain() }
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "The connection went away before the robot answered, which is also what taking the network does. Look for it on \(ssid) first: if it is there, the join worked."
                )
            )
        }
    }
}
