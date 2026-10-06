import ReachyKit
@testable import ReachyUI
import SwiftUI

// The store over the relay (#158): the Hub's catalogue, read by this device, with
// `apps.install` behind it. Every capture here parks a relayed session on a client
// that installs by name, which is what `AppStoreModel.isOverRelay` asks.
//
// No Installed segment, and the notice says why. Face Tracking reads installed
// because this visit installed it — the only way a card can, over the relay.
#Preview("Apps — over the relay") {
    let session = RobotSession.preview(address: nil, link: .remote, client: PreviewRelayStoreClient())
    PreviewScene.appStore(
        session,
        model: .preview(
            session: session,
            catalogue: Array(RobotApp.previewCatalogue.prefix(3)),
            installed: [],
            installedOverRelay: [RobotApp.previewCatalogue[1].id]
        )
    )
}

// This device read the Hub and failed, so the sentence is about this device — the
// robot was never asked.
#Preview("Apps — over the relay, Hub unreachable") {
    let session = RobotSession.preview(address: nil, link: .remote, client: PreviewRelayStoreClient())
    PreviewScene.appStore(
        session,
        model: .preview(
            session: session,
            catalogue: [],
            installed: [],
            error: "The Internet connection appears to be offline."
        )
    )
}

// There is no capture of an app the robot does not have over the relay: nothing the
// relay changes shows before Install is tapped, and `App detail — over the relay`
// was byte-identical to `App detail — not installed` in all four captures. The
// pages below are the ones the relay draws differently.

// One answer at the end and nothing before it, so the console a LAN install shows
// gives way to the sentence saying so.
#Preview("App detail — installing over the relay") {
    let session = RobotSession.preview(address: nil, link: .remote, client: PreviewRelayStoreClient())
    PreviewScene.appDetail(
        session,
        app: RobotApp.previewCatalogue[0],
        model: .preview(session: session, installed: []),
        install: .preview(state: .running(.install(RobotApp.previewCatalogue[0])), session: session)
    )
}

// Start, sent by the slug the install used, and in place of Update, Start on
// wake-up and Remove the sentence saying where they are.
#Preview("App detail — installed over the relay") {
    let session = RobotSession.preview(address: nil, link: .remote, client: PreviewRelayStoreClient())
    PreviewScene.appDetail(
        session,
        app: RobotApp.previewCatalogue[0],
        model: .preview(
            session: session,
            installed: [],
            installedOverRelay: [RobotApp.previewCatalogue[0].id]
        )
    )
}

// Unknown, not failed: the robot carries on installing whether anybody waits, and
// asking again costs nothing once it has.
#Preview("App detail — install unconfirmed over the relay") {
    let session = RobotSession.preview(address: nil, link: .remote, client: PreviewRelayStoreClient())
    PreviewScene.appDetail(
        session,
        app: RobotApp.previewCatalogue[0],
        model: .preview(session: session, installed: []),
        install: .preview(state: .unconfirmed(.install(RobotApp.previewCatalogue[0])), session: session)
    )
}

// The app the relay says is running: a bare name, no Restart (the relay has no
// such verb), and the LAN-only note where the store's three controls would be.
#Preview("Running app — over the relay") {
    let session = RobotSession.preview(
        address: nil,
        link: .remote,
        runningApp: .previewOverRelay,
        client: PreviewRelayStoreClient()
    )
    PreviewScene.appDetail(
        session,
        app: RobotAppStatus.previewOverRelay.app,
        model: .preview(session: session, installed: [])
    )
}

#Preview("Dock — over the relay", traits: .sizeThatFitsLayout) {
    PreviewScene.runningAppDock(.previewOverRelay, offersRestart: false)
}
