import ReachyDesign
import SwiftUI

/// The way into the remote list from the connection screen.
///
/// Deliberately not disabled while a discovery sweep runs, unlike the sections
/// around it: a robot reached through Hugging Face is not on this network, so a
/// sweep of this one says nothing about whether it can be reached.
///
/// `show` being optional is what hides the section — in a preview, or anywhere
/// the list has nowhere to be presented from, there is no entry point rather
/// than a dead one.
struct YourReachiesSection: View {
    var show: (() -> Void)?

    var body: some View {
        if let show {
            Section {
                Button {
                    show()
                } label: {
                    LabeledContent(.reachy("Your Reachies")) {
                        Text(.reachy("Through Hugging Face"))
                            .font(Typography.status)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(.reachy("Robots linked to your Hugging Face account, wherever they are."))
            }
        }
    }
}
