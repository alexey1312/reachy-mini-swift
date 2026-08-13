import ReachyKit
@testable import ReachyUI
import SwiftUI

#Preview("Apps — discover") {
    PreviewScene.appStore(.preview())
}

#Preview("Apps — installed") {
    PreviewScene.appStore(.preview(), model: .preview(section: .installed))
}

#Preview("Apps — update available") {
    PreviewScene.appStore(.preview(), model: .preview(section: .installed, hasUpdate: true))
}

// The running app now lives on the session — the store row reads it through the
// model, and the global dock reads the same value. Parking it on one session is
// what keeps the two agreeing.
#Preview("Apps — running") {
    let session = RobotSession.preview(runningApp: .preview(.running))
    PreviewScene.appStore(
        session,
        model: .preview(session: session, section: .installed, startupApp: "reachy_mini_dance")
    )
}

// Chess Coach is third in the daemon's own ordering, so a capture that puts it
// first is the lift itself — not merely the pin glyph.
#Preview("Apps — pinned") {
    PreviewScene.appStore(.preview(), model: .preview(pinned: ["someone/chess-coach"]))
}

// A relay session holds the same lock a local app does. The screen has to explain
// itself rather than just disable the buttons.
#Preview("Apps — held remotely") {
    PreviewScene.appStore(
        .preview(),
        model: .preview(lock: RobotAppLockStatus(state: .remoteSession, holderName: "alexey1312"))
    )
}

#Preview("Apps — loading") {
    PreviewScene.appStore(.preview(), model: .preview(catalogue: [], installed: [], loading: true))
}

#Preview("Apps — nothing installed") {
    PreviewScene.appStore(.preview(), model: .preview(section: .installed, catalogue: [], installed: []))
}

// The robot answered, but it could not reach Hugging Face — which is the robot's
// connectivity, not this app's.
#Preview("Apps — store unavailable") {
    PreviewScene.appStore(
        .preview(),
        model: .preview(
            catalogue: [],
            installed: [],
            error: "The daemon rejected the request (HTTP 503)"
        )
    )
}

// The two apps from Pollen, and the toolbar glyph filled in to say a scope is in
// force — the unfilled state is in every other `Apps —` reference.
#Preview("Apps — filtered to official") {
    PreviewScene.appStore(.preview(), model: .preview(scope: .official))
}

// Chess Coach is third in the daemon's own ordering and first alphabetically, so a
// capture that opens with it is the sort itself rather than a list that would have
// looked the same anyway.
#Preview("Apps — sorted by name") {
    PreviewScene.appStore(.preview(), model: .preview(sort: .name))
}

// A scope that empties the list. The wording has to send the reader to the filter
// rather than to the robot — nothing here failed.
#Preview("Apps — nothing matches the filter") {
    PreviewScene.appStore(.preview(), model: .preview(section: .installed, scope: .privateSpaces))
}

// MARK: - Detail sheet

#Preview("App detail — not installed") {
    PreviewScene.appDetail(.preview(), app: RobotApp.previewCatalogue[0])
}

#Preview("App detail — installed") {
    PreviewScene.appDetail(
        .preview(),
        app: RobotApp.previewCatalogue[0],
        model: .preview(section: .installed, startupApp: "reachy_mini_dance", hasUpdate: true)
    )
}

// A private Space needs the *robot* linked to an account, not this device.
#Preview("App detail — private space") {
    PreviewScene.appDetail(.preview(), app: RobotApp.previewCatalogue[3])
}

#Preview("App detail — installing") {
    PreviewScene.appDetail(
        .preview(),
        app: RobotApp.previewCatalogue[0],
        install: .preview(
            state: .running(.install(RobotApp.previewCatalogue[0])),
            log: PreviewScene.installerLines
        )
    )
}

#Preview("App detail — install failed") {
    PreviewScene.appDetail(
        .preview(),
        app: RobotApp.previewCatalogue[0],
        install: .preview(
            state: .failed(
                .install(RobotApp.previewCatalogue[0]),
                "No matching distribution found for reachy-mini-dance"
            ),
            log: PreviewScene.installerLines
        )
    )
}

// The three power states Start now depends on, and they are three separate
// pictures rather than one: the sleeping robot still offers Start (it wakes the
// robot itself, and only the footer says so), the stopped backend does not and
// carries the banner instead, and the wake in flight is the seconds in between.
#Preview("App detail — robot asleep") {
    PreviewScene.appDetail(
        .preview(status: .preview(motorMode: .disabled)),
        app: RobotApp.previewConversation,
        model: .preview(section: .installed)
    )
}

#Preview("App detail — robot backend stopped") {
    PreviewScene.appDetail(
        .preview(status: .preview(state: .stopped)),
        app: RobotApp.previewConversation,
        model: .preview(section: .installed)
    )
}

#Preview("App detail — waking up to start") {
    PreviewScene.appDetail(
        .preview(status: .preview(motorMode: .disabled), powerTransition: .wakingUp),
        app: RobotApp.previewConversation,
        model: .preview(section: .installed)
    )
}

// Neither success nor failure: the job register died with the daemon, so the
// installed list is the only thing that knows how it ended.
#Preview("App detail — robot restarted") {
    PreviewScene.appDetail(
        .preview(),
        app: RobotApp.previewCatalogue[0],
        install: .preview(state: .daemonRestarted(.install(RobotApp.previewCatalogue[0])))
    )
}
