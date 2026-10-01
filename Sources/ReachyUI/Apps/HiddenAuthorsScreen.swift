import ReachyKit
import SwiftUI

/// The authors whose apps a reader hid from Discover, and the way back for each.
///
/// The undo for `AppModerationActions`' Hide, which acts at once and leaves the
/// page. Reached from the row Discover adds while it is hiding anything, and from
/// the store's filter menu whenever anybody is hidden — so a reader who hid the
/// wrong author a moment ago finds them where the app went missing.
struct HiddenAuthorsScreen: View {
    let moderation: AppModeration
    let done: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(moderation.hiddenAuthors, id: \.self) { author in
                    LabeledContent {
                        Button(.reachy("Show")) {
                            moderation.unhide(author: author)
                        }
                        .buttonStyle(.borderless)
                    } label: {
                        Text(author)
                    }
                }
            } footer: {
                if !moderation.hiddenAuthors.isEmpty {
                    Text(.reachy(
                        "Their apps are left out of Discover on this device. Apps already on the robot stay installed."
                    ))
                }
            }
        }
        .overlay {
            if moderation.hiddenAuthors.isEmpty {
                ContentUnavailableView(
                    .reachy("No hidden authors"),
                    systemImage: "eye",
                    description: Text(.reachy("Hide an author from one of their apps in Discover."))
                )
            }
        }
        .navigationTitle(.reachy("Hidden authors"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(.reachy("Done"), action: done)
            }
        }
    }
}
