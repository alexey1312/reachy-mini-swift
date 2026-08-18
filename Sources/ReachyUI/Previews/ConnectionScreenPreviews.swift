import ReachyKit
@testable import ReachyUI
import SwiftUI

// The segments are the screen's shape now, so `route` is part of what a capture
// says: the Hugging Face and simulator previews verify nothing without it, because
// the section they are about is not on screen in the default segment.
//
// The address field is the exception, and that is the point of it having moved: it
// sits under the robot list in `Local`, so the three previews about it are captures
// of the default segment with something typed in.

#Preview("Connection — searching") {
    PreviewScene.connection(.preview(phase: .idle, status: nil, address: nil))
}

#Preview("Connection — robots found") {
    PreviewScene.connection(.preview(phase: .idle, status: nil, address: nil), browser: .preview())
}

// Denied Local Network permission looks exactly like an empty network from the API, so the screen
// has to say so itself.
#Preview("Connection — permission denied") {
    PreviewScene.connection(
        .preview(phase: .idle, status: nil, address: nil),
        browser: .preview(names: [], permissionDenied: true)
    )
}

#Preview("Connection — probing") {
    PreviewScene.connection(.preview(phase: .connecting(.handshaking), status: nil, address: nil))
}

// The decision no longer replaces the screen. The rail stays where it is, the buttons appear under
// it, and the list below goes inert rather than disappearing — which is what stops the layout
// jumping at the moment the reader is trying to read a failure.
#Preview("Connection — needs a decision") {
    PreviewScene.connection(
        .preview(
            phase: .connecting(.backendUnavailable(.preview, daemonMessage: "Backend not running")),
            status: nil,
            address: nil
        )
    )
}

#Preview("Connection — connect failed") {
    PreviewScene.connection(
        .preview(
            phase: .connecting(.failed(.connect, message: "Could not connect to the server.")),
            status: nil,
            address: nil
        )
    )
}

// `automaticConnectionAllowed: false` is what makes this state reachable at all, not
// preview dressing: while the sweep is running it rewrites `lastError` every 10 s, so
// the section is suppressed. Cancelling is what stops the sweep and lets the last
// failure stand still long enough to be read.
#Preview("Connection — error") {
    PreviewScene.connection(
        .preview(
            phase: .idle,
            status: nil,
            address: nil,
            error: "The daemon refused the handshake.",
            automaticConnectionAllowed: false
        ),
        browser: .preview()
    )
}

#Preview("Connection — reconnect paused") {
    PreviewScene.connection(
        .preview(phase: .idle, status: nil, address: nil, automaticConnectionAllowed: false),
        browser: .preview()
    )
}

// The state this screen exists for: the robot is stored from an earlier handshake but nothing
// answers at its address, which is what an empty discovery list used to hide.
#Preview("Connection — known robot not responding") {
    PreviewScene.connection(
        .preview(phase: .idle, status: nil, address: nil, automaticConnectionAllowed: false),
        browser: .preview(names: []),
        knownRobots: .preview([.preview(status: .unreachable)])
    )
}

#Preview("Connection — known robot on the network") {
    PreviewScene.connection(
        .preview(phase: .idle, status: nil, address: nil),
        browser: .preview(names: []),
        knownRobots: .preview([.preview(status: .reachable)])
    )
}

// A stored robot still being probed, beside a second robot only Bonjour knows about.
#Preview("Connection — known robot and a new one") {
    PreviewScene.connection(
        .preview(phase: .idle, status: nil, address: nil),
        browser: .preview(names: ["reachy-mini-9c81"]),
        knownRobots: .preview([.preview(status: .checking)])
    )
}

// The Hugging Face segment renders nothing without a way to present the list, which is the seam
// that hides it in previews. Its content therefore gets its own reference in `YourReachiesPreviews`;
// what this one covers is the empty segment plus the Bluetooth row that survives every segment.
#Preview("Connection — Hugging Face segment") {
    PreviewScene.connection(.preview(phase: .idle, status: nil, address: nil), route: .account)
}

#Preview("Connection — manual address typed") {
    PreviewScene.connection(
        .preview(phase: .idle, status: nil, address: nil),
        browser: .preview(names: []),
        manualInput: "192.168.1.42"
    )
}

#Preview("Connection — manual address invalid") {
    PreviewScene.connection(
        .preview(phase: .idle, status: nil, address: nil),
        browser: .preview(names: []),
        manualInput: "not an address"
    )
}

// The bug this section was moved out of the robot list for. Someone blocked from
// discovery goes on to type an address, and watches that fail just as silently,
// because the permission gates plain HTTP to the LAN and not only Bonjour. The
// banner is a section of the screen rather than of any segment, which is what this
// reference holds — see `Connection — Hugging Face segment` for the other half,
// where it survives a segment with no robot list in it at all.
#Preview("Connection — manual address, permission denied") {
    PreviewScene.connection(
        .preview(phase: .idle, status: nil, address: nil),
        browser: .preview(names: [], permissionDenied: true),
        manualInput: "192.168.1.42"
    )
}
