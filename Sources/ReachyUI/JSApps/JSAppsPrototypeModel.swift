import Foundation
import HuggingFaceAuth
import Observation
import ReachyKit

// The #159 prototype, which ships to nobody (ADR 0006).
#if DEBUG
    /// The #159 prototype's catalogue, its narrow sign-in, and the robot as central
    /// sees it through that sign-in — the three facts a hosted app needs before it can
    /// be opened, each shown on its own so a device run can say which one failed.
    ///
    /// **The narrow account is in memory only and belongs to this model** (ADR 0006).
    /// It is a second authorization of the same OAuth client for `openid profile`,
    /// never the account's own token, and it is gone when the screen is.
    @MainActor
    @Observable
    final class JSAppsPrototypeModel {
        enum Robot: Equatable {
            case unknown
            case resolving
            /// Central listed the robot, through the narrow token.
            case found(CentralRobot)
            /// Central answered, and this robot was not in the account's list.
            case notListed(count: Int)
            case failed(String)
        }

        let webAccount: HFAccount
        private(set) var apps: [JSApp] = []
        private(set) var catalogueError: String?
        private(set) var isLoadingCatalogue = false
        private(set) var robot: Robot = .unknown
        private(set) var authorizationError: String?
        private(set) var isAuthorizing = false

        private let catalogue: JSAppCatalogue
        private let browser: any HFWebAuthenticating

        init(
            catalogue: JSAppCatalogue = JSAppCatalogue(),
            browser: (any HFWebAuthenticating)? = nil,
            webAccount: HFAccount? = nil
        ) {
            self.catalogue = catalogue
            self.browser = browser ?? WebAuthenticationBrowser()
            self.webAccount = webAccount ?? HFAccount(
                configuration: .reachyMiniWebApps,
                store: InMemoryHFTokenStore()
            )
        }

        var isAuthorized: Bool {
            if case .signedIn = webAccount.state {
                true
            } else {
                false
            }
        }

        func loadCatalogue() async {
            isLoadingCatalogue = true
            defer { isLoadingCatalogue = false }
            do {
                apps = try await catalogue.apps()
                catalogueError = nil
            } catch {
                guard let message = RobotSession.message(for: error) else { return }
                catalogueError = message
            }
        }

        /// The second authorization: same client, `openid profile` only.
        func authorize(hardwareID: String?) async {
            authorizationError = nil
            isAuthorizing = true
            defer { isAuthorizing = false }
            do {
                let url = try webAccount.beginSignIn()
                let callback = try await browser.authenticate(
                    url: url,
                    callbackScheme: HFOAuthConfiguration.callbackScheme
                )
                await webAccount.completeSignIn(callback: callback)
                if case let .failed(reason) = webAccount.state {
                    authorizationError = reason
                    return
                }
            } catch is HFSignInModel.Cancelled {
                webAccount.signOut()
                return
            } catch {
                webAccount.signOut()
                authorizationError = error.localizedDescription
                return
            }
            await resolveRobot(hardwareID: hardwareID)
        }

        /// Asks central for the account's robots **with the narrow token** — which is
        /// the measurement: a listing here is central accepting a token that can do
        /// nothing else.
        func resolveRobot(hardwareID: String?) async {
            guard isAuthorized else { return }
            robot = .resolving
            let account = webAccount
            let relay = CentralRelayClient { await account.currentToken() }
            do {
                let robots = try await relay.robots()
                if let hardwareID, let match = robots.first(where: { $0.hardwareID == hardwareID }) {
                    robot = .found(match)
                } else {
                    robot = .notListed(count: robots.count)
                }
            } catch {
                robot = .failed(error.localizedDescription)
            }
        }

        /// The address to open `app` at, or `nil` until the token and the robot are
        /// both in hand.
        func embedURL(for app: JSApp, theme: JSAppEmbed.Theme) async -> URL? {
            guard case let .found(robot) = robot,
                  let token = await webAccount.currentToken(),
                  let userName = webAccount.username
            else { return nil }
            let credentials = JSAppEmbed.Credentials(
                hfToken: token,
                userName: userName,
                robotPeerID: robot.peerID,
                robotHardwareID: robot.hardwareID,
                signalingURL: CentralRelayClient.defaultBaseURL,
                theme: theme,
                appName: app.title
            )
            return try? JSAppEmbed.url(for: app, credentials: credentials)
        }
    }
#endif
