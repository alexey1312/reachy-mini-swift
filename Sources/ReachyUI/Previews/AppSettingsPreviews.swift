import ReachyDesign
@testable import ReachyUI
import SwiftUI

// The page itself is a `WKWebView`, which renders nothing headless and is not
// even mounted under `reachyPreviewMode` — so what these cover is everything
// around it: the navigation chrome, the loading state, and the failure a robot
// that stopped answering mid-load produces.
//
// `.ready` is deliberately absent. It is the one phase in which nothing but the
// unrenderable layer is on screen, which is the same reason `SceneViewport` has
// no reference for its own `.ready` — and unlike `CameraViewport.streaming`,
// this phase grows no chrome of its own to capture over it.
//
// Neither reference has a navigation bar in it, and that is the harness rather
// than the screen: here it is the root of `NavigationHost`'s stack, where an
// inline title with no toolbar item beside it has nothing to hold the bar open,
// while the app pushes it out of `AppDetailSheet` and the back button keeps the
// bar — with the title in it. So the blank strip at the top is neither a missing
// `navigationTitle` nor proof that one is missing; `Running app — conversation`
// is the reference that shows the row this is pushed from.

#Preview("App settings — loading") {
    PreviewScene.appSettings(.loading)
}

// The app was running when the row was tapped and had stopped by the time the
// page loaded — the single most likely way to land here, because the process
// serving the page is the one that crashes.
#Preview("App settings — failed") {
    PreviewScene.appSettings(.failed("Could not connect to the server."))
}
