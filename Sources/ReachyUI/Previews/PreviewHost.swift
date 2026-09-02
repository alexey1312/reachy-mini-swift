import ReachyDesign
@testable import ReachyUI
import SwiftUI

/// The two wrappers every preview scene is built from.
///
/// Internal rather than file-private, which is what they used to be: the scene
/// factories outgrew one file, and a `private` helper cannot be shared between two.
/// Nothing outside `Previews/` should call either — `reachyPreviewMode` is a
/// statement that no effect should run, and a screen making that claim about itself
/// is a bug, not a shortcut.
extension View {
    func preview() -> some View {
        environment(\.reachyPreviewMode, true)
    }
}

/// Navigation chrome for screen previews: the title and the toolbar are part of the screen, so a
/// snapshot has to include them.
///
/// Inside the storybook these toolbars end up in the app's own navigation bar rather than in the
/// card — SwiftUI hoists `.toolbar` out of the scaled card, and dropping this stack only makes
/// that worse, since a toolbar with no local container has nowhere else to go. The storybook hides
/// its root bar instead.
struct NavigationHost<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack { content }
    }
}
