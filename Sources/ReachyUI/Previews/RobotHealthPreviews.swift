import ReachyKit
@testable import ReachyUI
import SwiftUI

// Both halves answering: the daemon's control loop and the operating system read over SSH. The
// series are fixed arrays rather than samples — a sparkline over live data would redraw
// differently on every capture, and a reference that cannot repeat itself is a test that fails at
// random.
#Preview("State — both halves") {
    PreviewScene.robotHealth(.preview())
}

// The state a reader opens this screen to diagnose, and the only one where the thresholds are
// visible at all: a processor at 92%, memory past 90% and a board at 79 °C — one degree under the
// Raspberry Pi's soft-throttle point, so temperature is `elevated` while the other two are
// `critical`. A reference for the healthy state alone certifies no threshold whatsoever.
#Preview("State — under load") {
    PreviewScene.robotHealth(.preview(
        system: .previewLoaded,
        loop: ControlLoopStats(
            frequencyHz: 34.8,
            maxIntervalSeconds: 0.312,
            errorCount: 47,
            motorController: "ControlLoopStats(period=~28.7ms, read_dt=~9.10 ms, write_dt=~0.44 ms)"
        )
    ))
}

// Reachable, but nothing in the Keychain. The daemon's section is filled and the operating
// system's holds one button — which is the whole shape of the degradation, and the state every
// robot starts in.
#Preview("State — needs SSH") {
    PreviewScene.robotHealth(.preview(phase: .needsPassword))
}

// A robot that stopped answering `/proc` has not stopped answering its daemon: the control loop
// section stays whole and only the system half reports the failure. That the two fail
// independently is asserted in `RobotHealthModelTests`; this is what it looks like.
#Preview("State — SSH failed") {
    PreviewScene.robotHealth(.preview(phase: .failed("Lost the connection to the robot.")))
}

// Over the relay there is no route to port 22 at all (ADR 0003), so the system half is not a
// failure to retry — it is a thing this connection cannot do, and the footer says which. The
// screen is still reachable because the daemon's half works everywhere.
#Preview("State — over the relay") {
    PreviewScene.robotHealth(.preview(phase: .unavailable))
}

// A simulated backend on this network: `control_loop_stats` is filled only by the real robot
// backend, so the daemon's half is legitimately empty while the operating system's is not. The
// one state where the two halves swap places.
#Preview("State — no control loop") {
    PreviewScene.robotHealth(.preview(loop: nil))
}
