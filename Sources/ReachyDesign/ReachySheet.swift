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
    /// One axis is declared and the other is measured: the width is
    /// `Metrics.sheetWidth`, and `.fitted` then asks the content how tall it wants
    /// to be *at that width*.
    ///
    /// Two earlier shapes, each wrong in its own direction and both worth keeping
    /// here because the next person will reach for one of them:
    ///
    /// - **A minimum in both axes.** A `Form` and a `ScrollView` are *flexible*, so
    ///   neither ever wants more than the floor it is handed — the minimum was
    ///   therefore the final height of every sheet, and the sign-in sheet came up as
    ///   a 680 pt slab with one card adrift in the middle of it, taller than the
    ///   window it hung off.
    /// - **`.form` for the width.** It proposes about 435 pt on macOS, which is the
    ///   ~440 pt the bug was reported at: `LabeledContent` lost "Remote access" off
    ///   the leading edge and its sentence off the trailing one. A form's width is
    ///   the system's idea of a settings sheet, not of this one.
    ///
    /// **A no-op on iOS and iPadOS**, where the system decides sheet geometry and
    /// anything here would only fight `presentationDetents`. That is also why it is
    /// spelled `#if` rather than `#available`: this is a platform difference, not a
    /// version one — `presentationSizing` is available at this app's floor.
    func reachySheet() -> some View {
        #if os(macOS)
            frame(width: Metrics.sheetWidth)
                .presentationSizing(.fitted)
        #else
            self
        #endif
    }
}
