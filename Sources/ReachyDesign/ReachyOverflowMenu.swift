import SwiftUI

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
/// A destructive item that asks first cannot anchor its confirmation to this
/// menu: set state from the item and present the dialog from the screen, which
/// every caller here already does.
public struct ReachyOverflowMenu<Content: View>: ToolbarContent {
    private let label: LocalizedStringResource
    private let fallbackPlacement: ToolbarItemPlacement
    private let content: Content

    public init(
        _ label: LocalizedStringResource = .reachy("More"),
        fallbackPlacement: ToolbarItemPlacement = .automatic,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.fallbackPlacement = fallbackPlacement
        self.content = content()
    }

    public var body: some ToolbarContent {
        #if os(iOS) || os(visionOS)
            if #available(iOS 27.0, visionOS 27.0, *) {
                ToolbarOverflowMenu { content }
            } else {
                fallback
            }
        #else
            fallback
        #endif
    }

    private var fallback: some ToolbarContent {
        ToolbarItem(placement: fallbackPlacement) {
            Menu {
                content
            } label: {
                Label(label, systemImage: "ellipsis.circle")
            }
            .help(Text(label))
        }
    }
}
