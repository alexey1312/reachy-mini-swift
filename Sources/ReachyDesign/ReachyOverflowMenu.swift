import SwiftUI

public extension View {
    /// A screen's secondary actions, in the bar's own overflow menu.
    ///
    /// **One "more" per bar.** Three screens drew a `Menu` of their own behind an
    /// `ellipsis.circle`, and on iOS 27 the system adds an overflow button of its own
    /// the moment a bar runs out of room — which on iPhone Duo's vertical bars it does
    /// early, on the outer display above all. Two ellipses side by side are two menus
    /// that look the same and hold different things. `ToolbarOverflowMenu` is the
    /// system's menu, so the actions handed to it share one button with whatever
    /// overflowed (Apple, *Raise the bar with iPhone Duo*, 11:40 and 12:43).
    ///
    /// It is iOS and visionOS 27 only — `@available(macOS, unavailable)` — so a Mac
    /// and an older iOS keep the menu these screens always drew, under the same word
    /// and the same symbol, in the placement each one had (`fallbackPlacement`).
    ///
    /// **A view modifier, not toolbar content, and the reason is a linker error.**
    /// An `if #available` inside a `@ToolbarContentBuilder` goes through
    /// `ToolbarContentBuilder.buildLimitedAvailability`, and in the iOS 27.1 SDK
    /// that returns an opaque type whose descriptor SwiftUI does not export: a
    /// Release build failed to link with "Undefined symbol: opaque type descriptor
    /// for … buildLimitedAvailability", while every Debug build passed. Here the
    /// check sits in a `ViewBuilder`, which erases its limited branch to `AnyView`.
    ///
    /// A destructive item that asks first cannot anchor its confirmation to this
    /// menu: set state from the item and present the dialog from the screen, which
    /// every caller here already does.
    func reachyOverflowMenu(
        _ label: LocalizedStringResource = .reachy("More"),
        fallbackPlacement: ToolbarItemPlacement = .automatic,
        @ViewBuilder items: () -> some View
    ) -> some View {
        modifier(ReachyOverflowMenu(label: label, fallbackPlacement: fallbackPlacement, items: items()))
    }
}

private struct ReachyOverflowMenu<Items: View>: ViewModifier {
    let label: LocalizedStringResource
    let fallbackPlacement: ToolbarItemPlacement
    let items: Items

    func body(content: Content) -> some View {
        #if os(iOS) || os(visionOS)
            if #available(iOS 27.0, visionOS 27.0, *) {
                content.toolbar {
                    ToolbarOverflowMenu { items }
                }
            } else {
                content.toolbar { fallback }
            }
        #else
            content.toolbar { fallback }
        #endif
    }

    private var fallback: some ToolbarContent {
        ToolbarItem(placement: fallbackPlacement) {
            Menu {
                items
            } label: {
                Label(label, systemImage: "ellipsis.circle")
            }
            .help(Text(label))
        }
    }
}
