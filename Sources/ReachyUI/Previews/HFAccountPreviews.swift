import HuggingFaceAuth
import ReachyKit
@testable import ReachyUI
import SwiftUI

#Preview("HF — signed out") {
    PreviewScene.hfAccount(model: .preview())
}

// A fork that has not registered its own OAuth app: the one-tap button is absent
// rather than broken, and the footer says what to do instead. Spelled out rather
// than taken from `.reachyMini`, which carries a registered client id.
#Preview("HF — token only") {
    PreviewScene.hfAccount(model: .preview(configuration: .unregistered))
}

// Pushed from «Your Reachies», where the reason there is no list is that nobody is
// signed in — and no robot is connected either, so the linking half is absent.
#Preview("HF — sign-in screen") {
    PreviewScene.hfSignIn()
}

#Preview("HF — signed in, robot not linked") {
    PreviewScene.hfAccount(model: .preview(state: .signedIn(username: "alexey1312")))
}

#Preview("HF — robot linked") {
    PreviewScene.hfAccount(
        model: .preview(state: .signedIn(username: "alexey1312")),
        robotAccount: HFAuthStatus(isLoggedIn: true, username: "alexey1312"),
        relay: RelayStatus(state: .connected, message: "Connected to central", isConnected: true)
    )
}

// A Lite robot has no relay module at all, and the router answers with a state
// the relay's own enum does not contain.
#Preview("HF — relay unavailable") {
    PreviewScene.hfAccount(
        model: .preview(state: .signedIn(username: "alexey1312")),
        robotAccount: HFAuthStatus(isLoggedIn: true, username: "alexey1312"),
        relay: RelayStatus(state: .unavailable, message: "Coming soon to Lite version", isConnected: false)
    )
}

#Preview("HF — session expired") {
    PreviewScene.hfAccount(model: .preview(state: .needsReauth(username: "alexey1312")))
}

#Preview("HF — sign-in failed") {
    PreviewScene.hfAccount(
        model: .preview(error: "Hugging Face does not recognise this token")
    )
}

#Preview("HF — linking failed") {
    PreviewScene.hfAccount(
        model: .preview(state: .signedIn(username: "alexey1312")),
        linkError: "The daemon rejected the request (HTTP 400)"
    )
}

// Over the relay the robot half is one row and one button: the data channel carries
// `delete_hf_token` and nothing else about the account, so "Linked" is inferred from
// the session existing at all — central lists a robot only while it holds a token.
#Preview("Hugging Face — robot over the relay") {
    PreviewScene.hfAccountOverTheRelay()
}

// Daemon 1.10.0 onwards: the robot signs itself in and the card shows the code it
// is waiting on. No token crosses the local network, so the footer says so.
#Preview("HF — robot waiting on a code") {
    PreviewScene.hfAccount(
        deviceLogin: RobotDeviceLogin(
            sessionID: "9f2c",
            userCode: "WDJB-MJHT",
            verificationURI: URL(string: "https://huggingface.co/device")!
        )
    )
}

// Daemon 1.12 moved to a credential store of its own with no migration, so a robot
// linked before the update reads as unlinked after it (pollen-robotics/reachy_mini#1367).
#Preview("HF — robot signed out by 1.12") {
    PreviewScene.hfAccount(daemonVersion: "1.12.0")
}

// Before 1.10.0 there is no device code: the robot can only be handed a copy of this
// app's token, which needs a sign-in here and says the hop is unencrypted.
#Preview("HF — robot on 1.9, token copy") {
    PreviewScene.hfAccount(
        model: .preview(state: .signedIn(username: "alexey1312")),
        daemonVersion: "1.9.0"
    )
}
