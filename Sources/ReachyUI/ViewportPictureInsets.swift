import SwiftUI

private struct ViewportPictureInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    /// How far the camera's picture or the 3D twin stops short of each edge so that
    /// it keeps off iPhone Duo's fold. Set by `ViewportView`; zero anywhere else, so
    /// every other host and every capture lays out as before.
    var viewportPictureInsets: EdgeInsets {
        get { self[ViewportPictureInsetsKey.self] }
        set { self[ViewportPictureInsetsKey.self] = newValue }
    }
}
