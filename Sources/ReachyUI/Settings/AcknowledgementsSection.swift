import ReachyDesign
import SwiftUI

/// Credits the sticker artwork, and it is a licence obligation rather than a courtesy.
///
/// The sixteen characters are Pollen Robotics' "Reachies", published under the Apache
/// License 2.0. Section 4(a) of that licence asks that a copy of it reach whoever
/// receives the work — and the copy committed beside the art in `art/stickers/` only
/// ever reaches somebody who clones the repository, not somebody who installs from the
/// App Store. So the credit and the link ship inside the app. Section 4(b) is the
/// other half: the modifications have to be stated, which is why the footer names them
/// rather than crediting the artwork and stopping.
///
/// Section 6 grants no trademark rights, so the marks are acknowledged as Pollen's and
/// the app says plainly that it is not theirs. That is a separate question from
/// copyright and the reason this text is explicit where a bare "artwork by" would do.
///
/// Shown on every platform although only the iOS build embeds the pack: the sentence is
/// true of the project either way, and a `#if os(iOS)` here would buy nothing but a
/// second thing to keep in step.
struct AcknowledgementsSection: View {
    var body: some View {
        Section {
            if let url = URL(string: "https://www.apache.org/licenses/LICENSE-2.0") {
                Link(destination: url) {
                    Label(.reachy("Apache License 2.0"), systemImage: "arrow.up.forward.square")
                }
            }
        } header: {
            Text(.reachy("Acknowledgements"))
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Sticker artwork: “Reachies” by Pollen Robotics, used under the Apache License 2.0 and modified — resized and animated for Messages. Reachy and Reachy Mini are their trademarks; this app is unofficial."
                )
            )
        }
    }
}
