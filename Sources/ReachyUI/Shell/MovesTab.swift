import ReachyKit
import SwiftUI

/// Recorded moves at the root of a tab rather than two taps into a `Form`.
struct MovesTab: View {
    let session: RobotSession
    let router: ReachyRouter

    /// Only forwarded, to the soundboard's own copy of the wobbling switch. One
    /// instance per connection is the whole point — the state is a record of requests
    /// and cannot be read back, so a second model would disagree forever.
    let presence: PresenceModel

    var body: some View {
        @Bindable var router = router
        return NavigationStack {
            Group {
                if session.canPlayMoves {
                    MovesScreen(session: session, presence: presence)
                } else {
                    MovesUnavailableView()
                }
            }
            .hfAccountToolbar(isPresented: $router.showsAccount)
        }
    }
}
