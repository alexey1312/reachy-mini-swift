import ReachyDesign
@testable import ReachyUI
import SwiftUI

// The macOS Settings window's two panes, rendered on the iOS simulator like every
// other reference: the panes are the same views, only the window chrome is not.
#Preview("App settings window — appearance") {
    ReachyAppSettingsView(pane: .appearance)
        .preview()
}

#Preview("App settings window — privacy") {
    ReachyAppSettingsView(pane: .privacy)
        .preview()
}
