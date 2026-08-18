@testable import ReachyUI
import SwiftUI

// A Lite robot and the simulator are the same daemon on somebody's computer, so
// this row is the whole of what "connect to a Lite robot" looks like. It is
// mounted only on macOS (`ConnectionScreen.form` says why), which is why these
// captures are standalone rather than states of `Connection —`.
//
// All three are worth a reference and the last one most: it is where a reader
// with no daemon running spends their time, and it is the only place the app
// explains what a Lite robot needs.

#Preview("Local daemon — looking") {
    PreviewScene.localDaemonSection(.checking)
}

#Preview("Local daemon — serving") {
    PreviewScene.localDaemonSection(.reachable)
}

// The row is disabled here, which a capture of the reachable state alone could
// not distinguish from a row that is never tappable.
#Preview("Local daemon — nothing here") {
    PreviewScene.localDaemonSection(.unreachable)
}
