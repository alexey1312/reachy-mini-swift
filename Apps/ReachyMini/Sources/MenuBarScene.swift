#if os(macOS)
    import ReachyKit
    import ReachyUI
    import ReachyWidgetUI
    import SwiftUI

    /// The robot in the menu bar: awake or asleep, one button to change it, and the
    /// installed apps underneath.
    ///
    /// **This is the one macOS-specific piece of the feature.** Everything it draws
    /// is `MenuBarContentView`, which is ordinary SwiftUI in `ReachyWidgetUI` and
    /// carries its own previews and references; a scene has neither and can have
    /// neither, the same status `reachySheet()` has.
    ///
    /// Three decisions, each of which is a Mac measurement rather than a preference:
    ///
    /// - **`.window`, not `.menu`.** The `.menu` style renders its content as an
    ///   AppKit menu and drops anything that is not a `Button`, `Text`, `Divider` or
    ///   `Menu` — the artwork, the status header and every caption would simply not
    ///   be there.
    /// - **The label is an icon.** `MenuBarExtra`'s label slot honours only text and
    ///   images, so the state travels as the glyph `RobotWidgetContent.symbolName`
    ///   is chosen to carry, with the words spoken rather than drawn — the same trade
    ///   `RobotWidgetView.circularBody` makes inside a 76 pt ring.
    /// - **`openURL` rather than `openWindow(id:)`.** The app's own deep link routes
    ///   through the `onOpenURL` the widget already uses, so a tap lands on the right
    ///   tab for free and no `id:` has to be added to the `WindowGroup` — which would
    ///   reset every saved window frame once.
    struct ReachyMenuBarScene: Scene {
        @State private var model = MenuBarModel()
        @Environment(\.openURL) private var openURL

        var body: some Scene {
            MenuBarExtra {
                MenuBarContentView(content: model.content, isBusy: model.isBusy, onCommand: handle)
                    // A second scene entry point owes the theme the same line the
                    // `WindowGroup` has: a theme is applied where a scene starts,
                    // never inside a root view.
                    .reachyThemeFromSettings()
                    .task { model.refresh() }
            } label: {
                Label(model.content.status.title, systemImage: model.content.status.symbolName)
                    .labelStyle(.iconOnly)
            }
            .menuBarExtraStyle(.window)
        }

        /// `.open` never reaches the model: bringing the app forward is the one thing
        /// only a scene can do, and the model is deliberately free of any way to.
        private func handle(_ command: MenuBarCommand) {
            if case let .open(destination) = command {
                openURL(destination.url)
            } else {
                model.send(command)
            }
        }
    }
#endif
