import SwiftUI

public extension View {
    /// Declares this to be a sheet's content, which on macOS is the only way it gets
    /// a size.
    ///
    /// **A macOS sheet is sized by its content's ideal size, and this app's sheets
    /// have none.** Every one of them is a `Form`, a `ScrollView` or a
    /// `NavigationStack` over one, and none of those proposes an ideal width — so
    /// AppKit picks something cramped, and what does not fit is clipped rather than
    /// laid out again. Both halves of that came back from one build: the Hugging
    /// Face sheet's `LabeledContent` rows lost their labels off the leading edge and
    /// their values off the trailing one, and the onboarding step's heading was cut
    /// in half under the title.
    ///
    /// A minimum rather than a fixed size: a sheet is not resizable on macOS, so the
    /// minimum is what it takes, and content that genuinely wants more can still
    /// grow rather than being clipped a second time.
    ///
    /// **A no-op on iOS and iPadOS**, where the system decides sheet geometry and a
    /// minimum here would only fight `presentationDetents`. That is also why it is
    /// spelled `#if` rather than `#available`: this is a platform difference, not a
    /// version one.
    func reachySheet() -> some View {
        #if os(macOS)
            frame(minWidth: Metrics.sheet.width, minHeight: Metrics.sheet.height)
        #else
            self
        #endif
    }
}
