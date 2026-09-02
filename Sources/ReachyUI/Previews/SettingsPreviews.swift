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

// Behind a row on a real screen, so a reference taken through `SettingsScreen`
// shows none of these. The screen itself shows all of them — including the only
// way into the robot's files.
#Preview("Advanced — every row") {
    PreviewScene.advancedScreen(.preview())
}

// A relay session has no route to port 22 (ADR 0003), so Robot files is absent
// rather than present and failing. A reference for the offered state alone cannot
// tell a conditional row from a permanent one.
#Preview("Advanced — over the relay") {
    PreviewScene.advancedScreen(
        .preview(address: nil, link: .remote, client: PreviewRemoteRobotClient())
    )
}

// A Lite robot mounts neither `/wifi/*` nor `/cache/*`, so the network and
// maintenance rows go with them.
#Preview("Advanced — Lite robot") {
    PreviewScene.advancedScreen(.preview(status: .preview(wirelessVersion: false)))
}

// The app target may not supply a developer screen at all.
#Preview("Advanced — no developer tools") {
    PreviewScene.advancedScreen(.preview(), developerTools: false)
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

// MARK: - Wi-Fi join

// The scan is the whole list here, unlike the Bluetooth flow's: the HTTP route is not
// squeezed into one 180-byte message, so a name missing from it really is a network
// that stayed quiet.
#Preview("Wi-Fi join — networks found") {
    PreviewScene.wifiJoin(.preview(networks: ["Pollen HQ", "Pollen Guest", "eduroam"], selected: "Pollen HQ"))
}

// "Other network…" is a choice rather than a fallback, so it gets its own capture: the
// name field appears only under it.
#Preview("Wi-Fi join — typed name") {
    PreviewScene.wifiJoin(.preview(networks: ["Pollen HQ"], manualSSID: "Attic", code: "AB12C"))
}

#Preview("Wi-Fi join — scanning") {
    PreviewScene.wifiJoin(.preview(scanning: true))
}

// Reachable for as long as the robot takes to answer, and the robot answers before it
// switches — so this is a short state with a real picture.
#Preview("Wi-Fi join — sending") {
    PreviewScene.wifiJoin(.preview(phase: .sending, networks: ["Pollen HQ"], selected: "Pollen HQ", code: "AB12C"))
}

#Preview("Wi-Fi join — scan failed") {
    PreviewScene.wifiJoin(.preview(scanFailure: "The robot did not answer in time."))
}

// The end of the flow and the end of the session with it: nothing on this screen waits
// for the robot, because the link it would wait over is the one going down.
#Preview("Wi-Fi join — sent") {
    PreviewScene.wifiJoin(.preview(phase: .sent(ssid: "Pollen HQ")))
}

#Preview("Wi-Fi join — refused") {
    PreviewScene.wifiJoin(.preview(phase: .refused("The robot could not read the Wi-Fi password. Check the PIN.")))
}

// The outcome that is neither: the link went away before the robot answered, which
// is also what an accepted password does.
#Preview("Wi-Fi join — uncertain") {
    PreviewScene.wifiJoin(.preview(phase: .uncertain(ssid: "Pollen HQ")))
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
