import ReachyKit
@testable import ReachyUI
import SwiftUI

#Preview("Onboarding — welcome") {
    PreviewScene.onboarding(.preview(step: .welcome, link: nil))
}

// MARK: - Scan

#Preview("Onboarding — scanning") {
    PreviewScene.onboarding(.preview(step: .scan))
}

#Preview("Onboarding — one robot found") {
    PreviewScene.onboarding(.preview(step: .scan, link: .preview(discovered: [.previewNear])))
}

// Two robots means no "Connect to this robot" button — the choice has to be made in the list.
#Preview("Onboarding — two robots found") {
    PreviewScene.onboarding(.preview(step: .scan, link: .preview(discovered: [.previewNear, .previewFar])))
}

#Preview("Onboarding — connecting") {
    PreviewScene.onboarding(.preview(step: .scan, link: .preview(discovered: [.previewNear]), isBusy: true))
}

#Preview("Onboarding — Bluetooth off") {
    PreviewScene.onboarding(.preview(step: .scan, link: .preview(availability: .poweredOff)))
}

#Preview("Onboarding — Bluetooth denied") {
    PreviewScene.onboarding(.preview(step: .scan, link: .preview(availability: .unauthorized)))
}

// What the flow looks like in the iOS Simulator, which never has a radio.
#Preview("Onboarding — no Bluetooth hardware") {
    PreviewScene.onboarding(.preview(step: .scan, link: .preview(availability: .unsupported)))
}

#Preview("Onboarding — scan failed") {
    PreviewScene.onboarding(.preview(step: .scan, errorMessage: "Bluetooth is not ready."))
}

// MARK: - PIN

#Preview("Onboarding — PIN empty") {
    PreviewScene.onboarding(.preview(step: .pin))
}

#Preview("Onboarding — PIN typed") {
    PreviewScene.onboarding(.preview(step: .pin, pinInput: "4A7f9"))
}

#Preview("Onboarding — PIN wrong") {
    PreviewScene.onboarding(.preview(
        step: .pin,
        link: .preview(failedPINAttempts: 1),
        errorMessage: "Incorrect PIN"
    ))
}

// The robot's own throttle. It survives a reconnect, so the screen has to wait it out visibly.
#Preview("Onboarding — PIN locked out") {
    PreviewScene.onboarding(.preview(
        step: .pin,
        link: .preview(failedPINAttempts: 3),
        errorMessage: "Incorrect PIN",
        lockoutSeconds: 27
    ))
}

// MARK: - Network

// Daemon 1.10.0 onwards names the robot over Bluetooth, straight after the PIN.
#Preview("Onboarding — name typed") {
    PreviewScene.onboarding(.preview(step: .name, nameInput: "Kitchen Reachy"))
}

// A 1.9.x robot echoes `SET_NAME`, so the name has to wait for Settings.
#Preview("Onboarding — name unsupported") {
    PreviewScene.onboarding(.preview(step: .name, nameInput: "Kitchen Reachy", nameIsUnsupported: true))
}

#Preview("Onboarding — name refused") {
    PreviewScene.onboarding(.preview(
        step: .name,
        errorMessage: "The robot did not accept that name. Use 1 to 64 characters.",
        nameInput: "Kitchen Reachy"
    ))
}

#Preview("Onboarding — network list") {
    PreviewScene.onboarding(.preview(
        step: .network,
        link: .preview(networks: ["Home", "Cafe", "Studio"]),
        selectedSSID: "Home"
    ))
}

// The robot truncates its scan at 180 bytes without saying so, so manual entry is the ordinary
// case rather than the fallback.
#Preview("Onboarding — other network") {
    PreviewScene.onboarding(.preview(
        step: .network,
        link: .preview(networks: ["Home", "Cafe"]),
        manualSSID: "Studio 5GHz"
    ))
}

#Preview("Onboarding — network scan failed") {
    PreviewScene.onboarding(.preview(
        step: .network,
        errorMessage: "The robot did not answer in time."
    ))
}

#Preview("Onboarding — already on a network") {
    PreviewScene.onboarding(.preview(
        step: .network,
        link: .preview(
            networkStatus: WiFiStatus(mode: .wlan, connected: "Home"),
            networks: ["Home", "Cafe"]
        ),
        selectedSSID: "Home"
    ))
}

// MARK: - Joining

#Preview("Onboarding — joining") {
    PreviewScene.onboarding(.preview(step: .joining, joinState: .working))
}

#Preview("Onboarding — joined") {
    PreviewScene.onboarding(.preview(step: .joining, joinState: .joined))
}

#Preview("Onboarding — join gave up") {
    PreviewScene.onboarding(.preview(step: .joining, joinState: .gaveUp))
}

#Preview("Onboarding — join refused") {
    PreviewScene.onboarding(.preview(
        step: .joining,
        joinState: .refused("The robot accepts 182 bytes per message and this one is 264.")
    ))
}

// MARK: - Handoff

#Preview("Onboarding — handoff") {
    PreviewScene.onboarding(.preview(
        step: .handoff,
        link: .preview(networkStatus: .preview, robotAddress: "192.168.1.42")
    ))
}

// A robot that never reported an address: the sweep has only the hardware id to go on.
#Preview("Onboarding — handoff without address") {
    PreviewScene.onboarding(.preview(step: .handoff))
}
