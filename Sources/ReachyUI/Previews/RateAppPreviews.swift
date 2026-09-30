@testable import ReachyUI
import SwiftUI

// One state: the row is always there. The system prompt it sits beside has no
// preview and cannot have one — it is StoreKit's sheet, presented out of process.
#Preview("Rate on the App Store") {
    PreviewScene.rateApp()
}
