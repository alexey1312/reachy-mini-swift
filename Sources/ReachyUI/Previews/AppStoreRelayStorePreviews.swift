import ReachyKit
@testable import ReachyUI
import SwiftUI

// The store over the relay from daemon 1.13.0: the robot lists what it has, installs
// by Space id as a followed job, updates, removes and restarts. Only the startup app
// stays on the robot's own network. Every capture here parks a 1.13.0 status on the
// session, which is what `RobotSession.hasRelayAppStore` reads; the relay previews
// beside these park none, so they keep the 1.10 store and did not move.

/// Not `private`: Prefire copies each body into a generated file, where a private
/// helper is out of reach.
extension RobotSession {
    @MainActor
    static func previewRelayStore(runningApp: RobotAppStatus? = nil) -> RobotSession {
        .preview(
            status: .preview(wirelessVersion: false, version: "1.13.0"),
            address: nil,
            link: .remote,
            runningApp: runningApp,
            client: PreviewRelayStoreClient(carriesRelayAppStore: true)
        )
    }
}

// Installed is back, and the notice that said it could not be is gone.
#Preview("Apps — over the relay on 1.13, installed") {
    let session = RobotSession.previewRelayStore()
    PreviewScene.appStore(
        session,
        model: .preview(
            session: session,
            section: .installed,
            catalogue: Array(RobotApp.previewCatalogue.prefix(3)),
            installed: [.preview(name: "reachy-mini-dance", installed: true)],
            hasUpdate: true
        )
    )
}

#Preview("Apps — over the relay on 1.13, discover") {
    let session = RobotSession.previewRelayStore()
    PreviewScene.appStore(
        session,
        model: .preview(
            session: session,
            catalogue: Array(RobotApp.previewCatalogue.prefix(3)),
            installed: [.preview(name: "reachy-mini-dance", installed: true)]
        )
    )
}

// Update and Remove as on the LAN; no Start on wake-up, and the footer says where it is.
#Preview("App detail — installed over the relay on 1.13") {
    let session = RobotSession.previewRelayStore()
    PreviewScene.appDetail(
        session,
        app: RobotApp.previewCatalogue[0],
        model: .preview(
            session: session,
            section: .installed,
            installed: [.preview(name: "reachy-mini-dance", installed: true)],
            hasUpdate: true
        )
    )
}

// A job now, with the console a LAN install shows, fed by `apps.job_progress`.
#Preview("App detail — installing over the relay on 1.13") {
    let session = RobotSession.previewRelayStore()
    PreviewScene.appDetail(
        session,
        app: RobotApp.previewCatalogue[0],
        model: .preview(session: session, installed: []),
        install: .preview(
            state: .running(.install(RobotApp.previewCatalogue[0])),
            session: session,
            log: ["Resolving reachy-mini-dance from pollen-robotics/reachy-mini-dance", "Installing 3 packages"]
        )
    )
}

// The robot will not remove the app it starts on wake-up, and the way out is on its
// own network: the sentence says so rather than the daemon's "unset it".
#Preview("App detail — removal refused over the relay on 1.13") {
    let session = RobotSession.previewRelayStore()
    let installed = RobotApp.preview(name: "reachy-mini-dance", installed: true)
    PreviewScene.appDetail(
        session,
        app: RobotApp.previewCatalogue[0],
        model: .preview(session: session, section: .installed, installed: [installed]),
        install: .preview(
            state: .failed(
                .remove(installed),
                String(localized: .reachy(
                    // swiftlint:disable:next line_length
                    "The robot starts this app on wake-up. Turn that off on the robot's own network first, then remove it."
                ))
            ),
            session: session
        )
    )
}

// `apps.restart` exists from 1.13.0, so Restart is back beside Stop.
#Preview("Running app — over the relay on 1.13") {
    let session = RobotSession.previewRelayStore(runningApp: .previewOverRelay)
    PreviewScene.appDetail(
        session,
        app: RobotAppStatus.previewOverRelay.app,
        model: .preview(session: session, section: .installed, installed: [RobotAppStatus.previewOverRelay.app])
    )
}
