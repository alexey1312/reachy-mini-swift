import HuggingFaceAuth
import ReachyKit
import SwiftUI

// The #159 prototype, which ships to nobody (ADR 0006).
#if DEBUG
    /// Opens a hosted JS app above everything else. Handed down by the root; `nil`
    /// everywhere a preview or a test builds a screen on its own.
    struct JSAppOpener {
        let open: @MainActor (JSApp, URL) -> Void

        @MainActor
        func callAsFunction(_ app: JSApp, url: URL) {
            open(app, url)
        }
    }

    private struct JSAppOpenerKey: EnvironmentKey {
        static let defaultValue: JSAppOpener? = nil
    }

    extension EnvironmentValues {
        /// Spelled out rather than written with `@Entry`, like `reachyPreviewMode`.
        var reachyOpenJSApp: JSAppOpener? {
            get { self[JSAppOpenerKey.self] }
            set { self[JSAppOpenerKey.self] = newValue }
        }
    }

    /// Where a hosted JS app lives, and the hand-over around it (ADR 0006, #159).
    ///
    /// **Mounted on the root, above the gate and the shell, for the reason
    /// `RootSheets` is**: handing the robot over ends this app's own relay session,
    /// the session's phase leaves `.connected`, and the shell — with the Settings
    /// screen the app was opened from — is thrown away. A cover hung anywhere under
    /// it would go with it, page and robot session included.
    ///
    /// **The hand-over is the relay's alone.** Central admits one session per robot
    /// and the page opens its own, so a relayed session is ended before the page
    /// loads and dialled again once the page has let go. Over the LAN this app holds
    /// no central session at all, so nothing is released — and whether the LAN
    /// camera's own WebRTC session holds the daemon's lock against the page is one
    /// of the questions this prototype exists to answer on a robot.
    ///
    /// The reconnect goes through the connect gate, visibly, and that is the measured
    /// cost ADR 0006 asks about: the prototype shows it rather than hides it.
    struct RootJSAppHost: ViewModifier {
        let session: RobotSession
        let hfAccount: HFAccount
        /// Ends this app's relay session: the session first, then the link under it.
        let releaseRelay: @MainActor () -> Void
        let reconnect: @MainActor (CentralRobot) -> Void

        @State private var hosted: JSAppHostModel?
        /// Set from the tap until the page is up. Over the relay that wait is
        /// `freeRobot`, up to twenty seconds with `hosted` still nil, so `hosted`
        /// alone would let a second tap open the app twice.
        @State private var isOpening = false
        /// The relayed robot to dial again once the app has let go, by hardware id —
        /// its central peer id may well have changed by then.
        @State private var returnTo: String?

        /// How long central may take to stop reporting the robot busy after a session
        /// ends, each way.
        private static let handOverTimeout: Duration = .seconds(20)

        func body(content: Content) -> some View {
            content
                .environment(\.reachyOpenJSApp, JSAppOpener { app, url in open(app, url: url) })
            #if os(iOS)
                .fullScreenCover(item: $hosted) { model in
                    JSAppHostScreen(model: model) { closed() }
                }
            #else
                .sheet(item: $hosted) { model in
                    JSAppHostScreen(model: model) { closed() }
                        .frame(minWidth: 720, minHeight: 600)
                }
            #endif
        }

        private func open(_ app: JSApp, url: URL) {
            guard hosted == nil, !isOpening else { return }
            isOpening = true
            Task {
                defer { isOpening = false }
                if session.isRemote, let hardwareID = session.connectedIdentity?.hardwareID {
                    returnTo = hardwareID
                    releaseRelay()
                    _ = await freeRobot(hardwareID)
                }
                hosted = JSAppHostModel(app: app, url: url)
            }
        }

        private func closed() {
            hosted = nil
            guard let hardwareID = returnTo else { return }
            returnTo = nil
            Task {
                if let robot = await freeRobot(hardwareID) {
                    reconnect(robot)
                }
            }
        }

        /// The robot as central lists it once nobody holds it, or `nil` at the
        /// deadline. A listing that fails concludes nothing and is asked again.
        private func freeRobot(_ hardwareID: String) async -> CentralRobot? {
            let relay = CentralRelayClient { [hfAccount] in await hfAccount.currentToken() }
            let deadline = ContinuousClock.now + Self.handOverTimeout
            while ContinuousClock.now < deadline, !Task.isCancelled {
                if let robots = try? await relay.robots(),
                   let robot = robots.first(where: { $0.hardwareID == hardwareID }),
                   !robot.isBusy
                {
                    return robot
                }
                try? await Task.sleep(for: .seconds(1))
            }
            return nil
        }
    }
#endif
