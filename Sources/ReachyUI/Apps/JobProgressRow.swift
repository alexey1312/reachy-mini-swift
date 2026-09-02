import ReachyDesign
import ReachyKit
import SwiftUI

/// What the job is doing, in one row.
struct JobProgressRow: View {
    let state: AppInstallModel.State

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case let .running(operation):
            Label {
                Text(operation.progressCaption)
            } icon: {
                ProgressView()
                    .controlSize(.small)
            }
        case .succeeded:
            Label(.reachy("Done"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tone.success.style)
        case let .failed(_, reason):
            Label {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(.reachy("Failed"))
                    Text(reason)
                        .font(Typography.status)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.danger.style)
            }
        case .daemonRestarted:
            Label {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(.reachy("The robot restarted"))
                    Text(.reachy("It may have finished — check the installed list."))
                        .font(Typography.status)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Tone.warning.style)
            }
        }
    }
}
