import ReachyDesign
import SwiftUI

extension View {
    /// A Refresh item for the platform that has no pull gesture.
    ///
    /// On iOS every catalogue here is `.refreshable`, and the toolbar button two of
    /// them also carried could not show its own work: after the first listing there
    /// is no loading state to draw, and a LAN round trip is tens of milliseconds, so
    /// a tap drew no frame at all. The pull gesture at least has a spinner. macOS has
    /// no pull, so there the item is the only way to ask again — with ⌘R, which is
    /// what a Mac reader reaches for first, and a tooltip.
    ///
    /// Nothing on iOS, deliberately: a second Refresh beside a gesture that already
    /// refreshes is the same control twice.
    func reachyRefreshToolbar(isDisabled: Bool = false, action: @escaping () async -> Void) -> some View {
        modifier(RefreshToolbar(isDisabled: isDisabled, action: action))
    }
}

private struct RefreshToolbar: ViewModifier {
    let isDisabled: Bool
    let action: () async -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
            content.toolbar {
                ToolbarItem {
                    Button {
                        Task { await action() }
                    } label: {
                        Label(.reachy("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r")
                    .help(Text(.reachy("Refresh")))
                    .disabled(isDisabled)
                }
            }
        #else
            content
        #endif
    }
}
