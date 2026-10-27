import ReachyDesign
import SwiftUI

/// Rows of `AppDetailSheet` that read nothing but their argument — a file of their
/// own because `AppDetailSheet.swift` sits at SwiftLint's file length, which
/// `--strict` turns into a build failure.
extension AppDetailSheet {
    /// The last thing the app printed before it died. The daemon keeps ten stderr
    /// lines here, and on a robot whose journal is not served over the network this
    /// is the only crash output there is.
    func failureRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(.reachy("Last output"))
                .font(Typography.status.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(error)
                .font(Typography.consoleLine)
                .textSelection(.enabled)
        }
    }
}
