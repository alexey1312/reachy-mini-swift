import SwiftUI

private struct ReachyPreviewModeKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Suppresses the live work a screen starts on appear — Bonjour browsing, log and teleop
    /// WebSockets, viewport attachment.
    ///
    /// A snapshot has to be final on its first frame, and these all reconnect with backoff
    /// forever: left running they would keep retrying against an address that does not exist
    /// while the image is being captured. Previews hand the screen a model that is already in its
    /// end state and set this, so the screen renders that state instead of chasing a robot.
    ///
    /// Spelled out rather than written with `@Entry`: that macro ships in Xcode's SDKs and not in
    /// the pinned swift.org toolchain, so it would break `swift build` — see `.swiftformat`.
    ///
    /// It lives in `ReachyDesign` rather than `ReachyUI` because the design system reads it too:
    /// a headless capture is where `.buttonStyle(.glassProminent)` blanks the whole image, so
    /// `reachyButton` draws the bordered style under it and glass everywhere else.
    var reachyPreviewMode: Bool {
        get { self[ReachyPreviewModeKey.self] }
        set { self[ReachyPreviewModeKey.self] = newValue }
    }
}

public extension View {
    /// The same switch previews flip, reachable from the app target: the UI smoke
    /// test launches the app with `--reachy-smoke` so it renders frozen instead of
    /// chasing a robot that does not exist.
    func reachyPreviewMode(_ enabled: Bool) -> some View {
        environment(\.reachyPreviewMode, enabled)
    }
}
