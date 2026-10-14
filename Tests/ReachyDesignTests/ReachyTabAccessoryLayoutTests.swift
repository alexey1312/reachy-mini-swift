#if os(macOS)
    import AppKit
    @testable import ReachyDesign
    import SwiftUI
    import Testing

    /// The fallback strip's arrival must not raise the tab's minimum size (#188).
    ///
    /// On macOS a tab is the detail column of a split view, and AppKit adds each
    /// column's minimum into the window's. A strip that raised it made AppKit widen
    /// the window from inside a layout pass, and on one Mac that pass never settled.
    /// `HoldsMinimumSize` carries the measurements.
    ///
    /// The minimum is read the way the split view reads it: the size the view takes
    /// when it is offered nothing.
    @MainActor
    @Suite("Tab accessory layout")
    struct ReachyTabAccessoryLayoutTests {
        /// What the tab content stands in for: a `Form` or a list, which asks for no
        /// minimum of its own.
        private func tab(stripIsPresented: Bool) -> some View {
            Color.clear
                .reachyTabAccessoryFallback(isPresented: stripIsPresented) {
                    // Wider than the real strip, which measured 183 pt at its narrowest.
                    Color.red.frame(width: 240, height: Metrics.dockStrip)
                }
        }

        private func minimumSize(of view: some View) -> CGSize {
            NSHostingController(rootView: view).sizeThatFits(in: .zero)
        }

        @Test("the strip raises neither the minimum width nor the minimum height")
        func stripKeepsTheMinimum() {
            let without = minimumSize(of: tab(stripIsPresented: false))
            let with = minimumSize(of: tab(stripIsPresented: true))
            #expect(with == without)
        }

        @Test("the strip still takes the whole width it is given")
        func stripFillsTheWidth() {
            let offered = CGSize(width: 600, height: 400)
            let size = NSHostingController(rootView: tab(stripIsPresented: true)).sizeThatFits(in: offered)
            #expect(size == offered)
        }
    }
#endif
