import ReachyDesign
@testable import ReachyUI
import SwiftUI

// The macOS Settings window's two panes, rendered on the iOS simulator like every
// other reference: the panes are the same views, only the window chrome is not.
// Its own file, beside `AppSettingsPreviews.swift`, which is about an *app's*
// settings page — the two are unrelated and the names were one word apart.
#Preview("App settings window — appearance") {
    ReachyAppSettingsView(pane: .appearance)
        .preview()
}

#Preview("App settings window — notifications") {
    ReachyAppSettingsView(pane: .notifications)
        .preview()
}

#Preview("App settings window — privacy") {
    ReachyAppSettingsView(pane: .privacy)
        .preview()
}
