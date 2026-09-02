import ReachyDesign
import SwiftUI

/// The macOS Settings window (⌘,): the two things that are about this app rather
/// than about a robot.
///
/// Appearance and Privacy both also live in the Settings tab, which only exists
/// once a robot has answered — and a Mac reader expects ⌘, to work before that.
/// Without a `Settings` scene the menu item sat greyed out for as long as the app
/// has run, which on a Mac reads as an app that is not finished.
public struct ReachyAppSettingsView: View {
    enum Pane: Hashable {
        case appearance
        case privacy
    }

    @State private var pane: Pane

    public init() {
        self.init(pane: .appearance)
    }

    /// Internal so a reference can capture each pane.
    init(pane: Pane) {
        _pane = State(initialValue: pane)
    }

    public var body: some View {
        TabView(selection: $pane) {
            Tab(value: .appearance) {
                Form {
                    AppearanceSection()
                }
                .formStyle(.grouped)
            } label: {
                Label(.reachy("Appearance"), systemImage: "paintpalette")
            }
            Tab(value: .privacy) {
                PermissionsScreen()
            } label: {
                Label(.reachy("Privacy"), systemImage: "hand.raised")
            }
        }
        .frame(minWidth: 480, idealWidth: Metrics.sheetWidth, minHeight: 420)
    }
}
