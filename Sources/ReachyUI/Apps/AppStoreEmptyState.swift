import ReachyKit
import SwiftUI

/// Why the store's list is empty, in the order the reasons are worth hearing: the
/// search, then a failure, then a filter, then the section itself.
///
/// A view of its own because `AppStoreScreen` sits at SwiftLint's file and type
/// limits; it reads the screen's model and writes one thing back (Show all apps).
struct AppStoreEmptyState: View {
    let model: AppStoreModel

    var body: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.lastError != nil {
            // Over the relay the catalogue is read by this device, so it is this
            // device's connection that failed — the robot was never asked.
            ContentUnavailableView(
                .reachy("Store unavailable"),
                systemImage: "wifi.exclamationmark",
                description: Text(
                    model.isOverRelay
                        ? .reachy("This device could not reach Hugging Face. Refresh once it is back online.")
                        : .reachy("The robot could not reach Hugging Face. Refresh once it is back online.")
                )
            )
            // Below the error on purpose: a filter over a catalogue that never arrived
            // is not why the list is empty, and saying so would send the reader to
            // clear a filter that was never the problem.
        } else if model.scope != .all {
            ContentUnavailableView {
                Label(.reachy("Nothing matches this filter"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(.reachy("No app in this section is filed under that heading."))
            } actions: {
                Button(.reachy("Show all apps")) { model.scope = .all }
            }
        } else {
            switch model.shownSection {
            case .installed:
                ContentUnavailableView(
                    .reachy("No apps installed"),
                    systemImage: "square.stack.3d.up.slash",
                    description: Text(.reachy("Browse Discover to install one from Hugging Face."))
                )
            case .discover:
                ContentUnavailableView(
                    .reachy("Nothing to show"),
                    systemImage: "square.stack.3d.up.slash",
                    description: Text(discoverDescription)
                )
            }
        }
    }

    /// An empty Discover is the robot's answer — unless every app it listed is by
    /// somebody the reader hid, which is theirs and is said as such. The row under
    /// the list leads back to them either way.
    private var discoverDescription: LocalizedStringResource {
        if model.hidesSomeOfDiscover {
            .reachy("Every app here is by an author you hid.")
        } else if model.isOverRelay {
            .reachy("Hugging Face lists no apps the robot can install.")
        } else {
            .reachy("The robot found no apps on Hugging Face.")
        }
    }
}
