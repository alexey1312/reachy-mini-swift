#if DEBUG
    import Foundation

    /// A relayed robot whose daemon answers `apps.install` — 1.10.0 and later — as a
    /// preview fixture.
    ///
    /// A client of its own rather than a flag on `PreviewRemoteRobotClient`: that one
    /// is every other relay reference, and conforming it to `RobotAppsClient` would
    /// hand all of them a running-app dock and an Apps tab they have never drawn.
    /// Nothing here answers; a preview parks the store's state on the model.
    public struct PreviewRelayStoreClient: RobotAPIClient, RobotAppsClient {
        public var identity: RobotIdentity
        public var status: Components.Schemas.DaemonStatus

        public init(
            identity: RobotIdentity = .preview,
            status: Components.Schemas.DaemonStatus = .preview(wirelessVersion: false, version: "1.11.0")
        ) {
            self.identity = identity
            self.status = status
        }

        public var offersAppStore: Bool {
            false
        }

        public var installsFromCatalogue: Bool {
            true
        }

        public var offersRestart: Bool {
            false
        }

        public func handshake() async throws -> RobotConnection.Handshake {
            .init(identity: identity, status: status, supportsRename: false)
        }

        public func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
            status
        }

        public func wakeUp() async throws -> String {
            ""
        }

        public func gotoSleep() async throws -> String {
            ""
        }
    }

    public extension RobotAppStatus {
        /// What the relay says about a running app: a name and no more. `_status_dict`
        /// sends no `extra`, so there is no title, no emoji and no card — the same bare
        /// status the LAN joins back from the installed list, with no list to join.
        static let previewOverRelay = RobotAppStatus(
            app: RobotApp(Components.Schemas.AppInfo(name: "reachy_mini_dance", sourceKind: .installed)),
            state: .running
        )
    }
#endif
