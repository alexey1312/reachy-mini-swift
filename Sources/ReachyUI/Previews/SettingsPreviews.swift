import ReachyKit
@testable import ReachyUI
import SwiftUI

// MARK: - The screen

#Preview("Settings — wireless robot") {
    PreviewScene.settings(.preview())
}

// A Lite robot mounts neither `/wifi/*` nor `/update/*`, so both cards are gone —
// and the footer now says why, which is the half that used to be missing. An
// absence with no reason attached is `MaintenanceCard`'s rule applied to a screen.
#Preview("Settings — Lite robot") {
    PreviewScene.settings(.preview(status: .preview(wirelessVersion: false)))
}

// The same absence for a different reason, and the sentence differs accordingly:
// a simulated robot has no Wi-Fi to configure rather than a Wi-Fi somewhere else.
#Preview("Settings — simulator") {
    PreviewScene.settings(.preview(status: .preview(wirelessVersion: false, simulationEnabled: true)))
}

// `/api/daemon/robot-name` postdates 1.9.0, so the field is greyed out and the footer
// says what would make it editable — rather than a save that can only 404.
#Preview("Settings — rename unavailable") {
    PreviewScene.settings(.preview(supportsRename: false))
}

// Audio needs the backend up; the rest of the screen does not.
#Preview("Settings — backend stopped") {
    PreviewScene.settings(.preview(status: .preview(state: .stopped)))
}

// MARK: - The Advanced group

// Closed on a real screen, and below the fold on both snapshot devices, so a
// reference taken through `SettingsScreen` shows none of these rows. Standalone
// and open, it shows all of them — including the only way into the robot's files.
#Preview("Advanced — every row") {
    PreviewScene.advancedSection(.preview())
}

// A relay session has no route to port 22 (ADR 0003), so Robot files is absent
// rather than present and failing. A reference for the offered state alone cannot
// tell a conditional row from a permanent one.
#Preview("Advanced — over the relay") {
    PreviewScene.advancedSection(
        .preview(address: nil, link: .remote, client: PreviewRemoteRobotClient())
    )
}

// A Lite robot mounts neither `/wifi/*` nor `/cache/*`, so the network and
// maintenance rows go with them.
#Preview("Advanced — Lite robot") {
    PreviewScene.advancedSection(.preview(status: .preview(wirelessVersion: false)))
}

// The app target may not supply a developer screen at all.
#Preview("Advanced — no developer tools") {
    PreviewScene.advancedSection(.preview(), developerTools: false)
}

// MARK: - Maintenance

// Both actions delete something on the robot and neither can be undone from here,
// so the sentence saying what goes comes above the button that sends it.

#Preview("Maintenance — idle") {
    PreviewScene.maintenanceCard()
}

#Preview("Maintenance — clearing the cache") {
    PreviewScene.maintenanceCard(.preview(running: .clearHuggingFaceCache))
}

#Preview("Maintenance — cleared") {
    PreviewScene.maintenanceCard(.preview(finished: .clearHuggingFaceCache))
}

// The daemon does not stop a running app before deleting the environment it runs
// in, so the client refuses instead — and names the app, because a greyed-out
// button on its own tells the reader nothing to act on.
#Preview("Maintenance — an app is running") {
    PreviewScene.maintenanceCard(runningApp: .preview(.running))
}

#Preview("Maintenance — failed") {
    PreviewScene.maintenanceCard(.preview(error: "The robot rejected the request (HTTP 500)."))
}

// MARK: - System update

#Preview("System update — idle") {
    PreviewScene.updateCard(.idle)
}

// The beta channel closed. Reachable only on a robot whose daemon predates the
// PyPI ranking fix, so it is seeded rather than waited for.
#Preview("System update — pre-release refused") {
    PreviewScene.updateCard(.upToDate(current: "1.9.0"), daemonVersion: "1.9.0")
}

#Preview("System update — checking") {
    PreviewScene.updateCard(.checking)
}

#Preview("System update — up to date") {
    PreviewScene.updateCard(.upToDate(current: "1.9.1"))
}

// The robot's own connectivity, not the app's — saying "the check failed" would send the user
// looking in the wrong place.
#Preview("System update — robot offline") {
    PreviewScene.updateCard(.robotOffline(current: "1.9.0"))
}

#Preview("System update — available") {
    PreviewScene.updateCard(.available(current: "1.9.0", latest: "1.9.1"))
}

#Preview("System update — installing") {
    PreviewScene.updateCard(.installing, log: PreviewScene.installerLines)
}

// The log socket closing is what the daemon restarting looks like, so this is a success state.
#Preview("System update — restarting") {
    PreviewScene.updateCard(.restarting, log: PreviewScene.installerLines)
}

#Preview("System update — finished") {
    PreviewScene.updateCard(.finished(version: "1.9.1"), log: PreviewScene.installerLines)
}

#Preview("System update — failed") {
    PreviewScene.updateCard(.failed("The robot reported that the update failed."))
}

// MARK: - Wi-Fi

#Preview("Wi-Fi — on a network") {
    PreviewScene.wifiCard(status: .preview)
}

#Preview("Wi-Fi — own hotspot") {
    PreviewScene.wifiCard(status: WiFiStatus(mode: .hotspot, connected: nil, known: ["Home"]))
}

// A failed join drops the robot back onto its hotspot and leaves the reason here, since the
// connect route answers before it has tried anything.
#Preview("Wi-Fi — join failed") {
    PreviewScene.wifiCard(
        status: WiFiStatus(mode: .hotspot, connected: nil, known: ["Home", "Cafe"]),
        joinError: "Secrets were required, but not provided."
    )
}

#Preview("Wi-Fi — status unavailable") {
    PreviewScene.wifiCard(loadFailure: "The robot did not answer in time.")
}
