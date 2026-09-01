import ReachyDesign
import ReachyKit
import ReachyMedia
import ReachyScene
@testable import ReachyUI
import SwiftUI

// The root is a gate or a five-tab shell and nothing else, so every capture here is one of those two.
// The iPad shots are the ones carrying `.sidebarAdaptable`: the same five tabs, as a sidebar.
//
// **They are also the ones carrying the viewport's trailing column**, on every shell capture with a
// source to show. Nothing here asks for it — `FloatingViewportModifier` writes `hasTabBar` from the
// size class before the first frame — so the iPhone and iPad halves of one preview legitimately show
// two different things, and no injected value can change that.
//
// **On iPad that includes the `tab: .live` captures, and they no longer show a viewport at all.** A
// sidebar keeps the picture in the column for the whole connection — one host, because two was what
// let a second `RealityView` steal the robot — so the Live tab there draws the controller instead, or
// `ControlsUnavailableView` where the connection cannot drive the robot. Both are captured in place
// rather than standalone, which is also the whole of `LiveUnavailableView`'s cover.

#Preview("Root — idle") {
    PreviewScene.root(.preview(phase: .idle, status: nil, address: nil))
}

#Preview("Root — connecting") {
    PreviewScene.root(.preview(phase: .connecting(.handshaking), status: nil, address: nil))
}

// The gate's other branch: start / continue / cancel, with the discovery list suppressed. The
// orienting line goes with it — a decision the user has to make is not something to talk over — and
// the readable width still holds, which is what this capture is for on iPad.
#Preview("Root — gate needs a decision") {
    PreviewScene.root(
        .preview(
            phase: .connecting(.backendUnavailable(.preview, daemonMessage: "Backend not running")),
            status: nil,
            address: nil
        )
    )
}

#Preview("Root — connected") {
    PreviewScene.root(.preview(), viewport: .preview(sceneModel: .preview(.buildingScene)))
}

// The pair to `Root — connected`, and it only means anything read against it: same robot, same tab,
// same everything except the switch on the Live tab. Without both, a capture with the viewport back
// in its tab cannot say whether the second place is switchable or merely absent.
//
// **Renamed from `Root — mini window off`, because the switch governs two things now.** One key, one
// toggle, and `hasTabBar` decides what it is called — so this capture is a window switched off on
// iPhone and a column switched off on iPad, and the old name was wrong on half of its own references.
#Preview("Root — viewport switched off") {
    PreviewScene.root(
        .preview(),
        viewport: .preview(sceneModel: .preview(.buildingScene)),
        floating: .preview(isEnabled: false)
    )
}

// `.unreachable` keeps the shell rather than dropping back to the gate: a network blip must not pull
// the tab bar out from under a finger. This is the capture that proves it.
#Preview("Root — unreachable") {
    PreviewScene.root(
        .preview(phase: .unreachable(.preview)),
        viewport: .preview(sceneModel: .preview(.buildingScene))
    )
}

// Without a running backend there is no geometry and no state stream, so the Live tab says so rather
// than showing an empty viewport.
#Preview("Root — no live view") {
    PreviewScene.root(
        .preview(status: .preview(state: .stopped)),
        viewport: .preview(address: nil),
        tab: .live
    )
}

#Preview("Root — live tab") {
    PreviewScene.root(
        .preview(),
        viewport: .preview(sceneModel: .preview(.buildingScene)),
        tab: .live
    )
}

// The one state that renders the asleep banner in place, pinned to the top of the tab.
#Preview("Root — live tab asleep") {
    PreviewScene.root(
        .preview(status: .preview(motorMode: .disabled)),
        viewport: .preview(sceneModel: .preview(.buildingScene)),
        tab: .live
    )
}

// Neither Moves-over-the-network nor Settings has a root capture, and both for the same reason —
// see `AGENTS.md`. `MovesScreenPreviews` and `SettingsPreviews` cover those screens; that they sit at
// the root of a tab is what `Root — relay moves tab` below shows, from a state that needs no `.task`.

// The dock, in place. What these have to show is a **tab bar that is still on screen**, with the strip
// above it and the tab's content inset to clear it. They used to be described as verifying that the
// strip landed *below* the bar; for five releases they recorded the opposite and nobody read them that
// way — the bar is simply absent from the pre-fix images, and `Root — connected` beside them is where
// it should have been. When one of these moves, check for the bar first and the strip second.
//
// They capture the fallback placement, because `PreviewScene.root` forces it for a reason written out
// there: an enabled `tabViewBottomAccessory` blanks the whole capture. There is no root reference for
// the system slot and there cannot be one — the strip it would hold is captured on its own instead, as
// `Dock — expanded`.
#Preview("Root — dock on the robot tab") {
    PreviewScene.root(
        .preview(runningApp: .preview(.running)),
        viewport: .preview(sceneModel: .preview(.buildingScene))
    )
}

// The reason the dock was hoisted out of the Apps tab: it is the same strip here, and the store below
// it no longer carries a second copy of the same control.
// No viewport source, so no floating window over it: this capture is about the strip,
// and `Root — floating viewport over the dock` is the one about the two together.
#Preview("Root — dock on the apps tab") {
    PreviewScene.root(
        .preview(runningApp: .preview(.running)),
        viewport: .preview(address: nil),
        tab: .apps
    )
}

// A crashed app keeps the strip until it has been read, and offers Dismiss rather than Stop.
#Preview("Root — dock, crashed app") {
    PreviewScene.root(
        .preview(runningApp: .previewCrashed),
        viewport: .preview(sceneModel: .preview(.buildingScene))
    )
}

// A daemon that reports no camera offers no switcher and shows the 3D model alone. **A wired robot
// is not that case** — the comment here used to say it was, and `hasCamera` used to agree: a Lite
// unit has a Raspberry Pi Camera v3 and its daemon names it `"lite"`. What genuinely leaves
// `camera_specs_name` empty is `--no-media`, a camera that failed to enumerate, or a media server
// that did not come up, so that is what this preview now says.
// Captured on the Live tab: that is the only place the flag changes anything, and on the robot tab
// this preview was byte-identical to `Root — connected` and verified nothing.
#Preview("Root — no camera") {
    PreviewScene.root(
        .preview(status: .preview(cameraSpecsName: "")),
        viewport: .preview(sceneModel: .preview(.buildingScene)),
        tab: .live
    )
}

// The relay session, which the root used to treat as no session at all.
#Preview("Root — over the relay") {
    let link = RemoteRobotLink.preview()
    return PreviewScene.root(
        .preview(address: nil, link: .remote, client: PreviewRemoteRobotClient()),
        viewport: .preview(
            content: .camera,
            cameraSession: link.camera,
            source: .remote(link.camera, connection: .preview())
        ),
        hfAccount: PreviewScene.account(in: .signedIn(username: "alexey1312")),
        remoteLink: link
    )
}

// The Live tab over the relay shows the camera the link already holds, rather than one it would dial.
#Preview("Root — relay live tab") {
    let link = RemoteRobotLink.preview()
    return PreviewScene.root(
        .preview(address: nil, link: .remote, client: PreviewRemoteRobotClient()),
        viewport: .preview(
            content: .camera,
            cameraSession: link.camera,
            source: .remote(link.camera, connection: .preview())
        ),
        tab: .live,
        hfAccount: PreviewScene.account(in: .signedIn(username: "alexey1312")),
        remoteLink: link
    )
}

// The move library is HTTP-only, so the relay reaches none of it. The tab stays and says why, which is
// what an unconditional tab buys over one that disappears.
#Preview("Root — relay moves tab") {
    PreviewScene.root(
        .preview(address: nil, link: .remote, client: PreviewRemoteRobotClient()),
        viewport: .preview(address: nil),
        tab: .moves,
        hfAccount: PreviewScene.account(in: .signedIn(username: "alexey1312"))
    )
}

// The store is not merely unreached over the relay — the data channel carries no app command at all —
// so the screen names that instead of claiming no robot is connected.
#Preview("Root — apps need the local network") {
    PreviewScene.root(
        .preview(address: nil, link: .remote, client: PreviewRemoteRobotClient()),
        viewport: .preview(address: nil),
        tab: .apps,
        hfAccount: PreviewScene.account(in: .signedIn(username: "alexey1312"))
    )
}

// Where signing in matters most: no robot yet, so the gate has the whole screen, and the remote list
// below stays empty until it happens.
#Preview("Root — idle, signed in") {
    PreviewScene.root(
        .preview(phase: .idle, status: nil, address: nil),
        hfAccount: PreviewScene.account(in: .signedIn(username: "alexey1312"))
    )
}

// The session lapsed and cannot be renewed silently — worth seeing before the next thing that needs
// it fails.
#Preview("Root — session expired") {
    PreviewScene.root(
        .preview(phase: .idle, status: nil, address: nil),
        hfAccount: PreviewScene.account(in: .needsReauth(username: "alexey1312"))
    )
}
