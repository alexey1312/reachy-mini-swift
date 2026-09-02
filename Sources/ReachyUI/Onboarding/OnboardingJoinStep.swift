import ReachyDesign
import ReachyKit
import SwiftUI

/// Waits out the join.
///
/// The robot answers the sealed password immediately and does the joining afterwards, so
/// there is nothing to read but its own status — polled until it reports itself on the
/// network or the budget its `nmcli` retries need runs out.
struct OnboardingJoinStep: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(title: title, message: message) {
            Section {
                switch model.joinState {
                case .working:
                    HStack(spacing: Space.sm) {
                        ProgressView()
                        Text(.reachy("This takes up to a minute."))
                            .foregroundStyle(.secondary)
                    }
                case .joined:
                    Label(.reachy("Connected"), systemImage: "checkmark.circle")
                        .foregroundStyle(Tone.success.style)
                case .gaveUp:
                    Label(
                        .reachy(
                            // swiftlint:disable:next line_length
                            "The robot has put its own reachy-mini-ap network back up, so nothing is lost — it is waiting to be told again."
                        ),
                        systemImage: "arrow.uturn.backward"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                case let .refused(reason):
                    ReachyErrorRow(reason)
                }
            } footer: {
                linkBudget
            }
        } actions: {
            switch model.joinState {
            case .working:
                EmptyView()
            case .joined:
                ReachyActionButton(.reachy("Continue"), fullWidth: true) {
                    model.continueAfterJoin()
                }
            case .gaveUp, .refused:
                ReachyActionButton(.reachy("Try again"), fullWidth: true) {
                    model.editNetwork()
                }
            }
        }
    }

    private var title: String {
        switch model.joinState {
        case .working: String(localized: .reachy("Joining the network"))
        case .joined: String(localized: .reachy("The robot is on the network"))
        case .gaveUp: String(localized: .reachy("The robot could not join"))
        case .refused: String(localized: .reachy("The robot refused the password"))
        }
    }

    private var message: String {
        switch model.joinState {
        case .working:
            String(localized: .reachy("The password went across encrypted. The robot is trying it now."))
        case .joined:
            String(localized: .reachy("It will answer on the network from here on, and Bluetooth is no longer needed."))
        case .gaveUp:
            String(
                localized: .reachy(
                    "It tried three times and gave up, which is a wrong password far more often than anything else."
                )
            )
        case .refused:
            String(localized: .reachy("It never got as far as trying the network."))
        }
    }

    /// What one Bluetooth message can carry, next to what the link would accept by
    /// fragmenting. The sealed password is around 260 bytes and the robot reassembles
    /// nothing, so these two numbers are the difference between Bluetooth setup working
    /// on a given phone and having to go through the robot's own access point instead.
    @ViewBuilder
    private var linkBudget: some View {
        if let session = model.session {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Bluetooth link: \(session.singlePacketWriteLength) bytes per message, \(session.attributeWriteLength) before iOS splits it"
                )
            )
            .font(Typography.consoleLine)
        }
    }
}
