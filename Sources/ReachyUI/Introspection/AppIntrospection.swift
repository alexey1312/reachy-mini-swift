#if DEBUG
    import Foundation
    import ReachyIntrospection
    import ReachyKit

    /// The app as the introspection tree reads it: the root, then a sheet, the
    /// connect gate, the first run or the tab shell.
    ///
    /// The fork is the one `ReachyRootView.body` takes, asked through the same
    /// `ConnectProgressModel.releasesGate(for:)`. A sheet comes first because a
    /// sheet covers whatever is under it, and the tree refuses an action on a
    /// covered node.
    @MainActor
    enum AppIntrospection {
        private struct State: Encodable {
            let phase: String
            let robot: String?
        }

        static func tree(
            session: RobotSession,
            router: ReachyRouter,
            progress: ConnectProgressModel,
            registry: IntrospectionRegistry
        ) -> IntrospectionTree {
            IntrospectionTree {
                IntrospectionNode(
                    name: "App",
                    state: .state(State(phase: session.phase.introspectionName, robot: session.phase.robotName)),
                    child: {
                        if let sheet = router.sheetNode {
                            sheet
                        } else if progress.releasesGate(for: session.phase), session.offersFirstRun {
                            // The first run has no node of its own yet: its name says
                            // where the app is, and it offers nothing.
                            IntrospectionNode(name: "FirstRun")
                        } else if progress.releasesGate(for: session.phase) {
                            router.shellNode(session: session)
                        } else {
                            registry.gate?.introspectionNode(progress: progress, router: router)
                        }
                    }
                )
            }
        }
    }

    extension JSONValue {
        /// A node's state from a value that always encodes: strings, numbers,
        /// Booleans and arrays of them.
        static func state(_ value: some Encodable) -> JSONValue {
            (try? JSONValue(encoding: value)) ?? .null
        }
    }

    extension RobotSession.ConnectionPhase {
        /// A stable name for an agent to compare. Not a caption: a reader of the
        /// app sees `ConnectHeader`'s sentence, which is localized.
        var introspectionName: String {
            switch self {
            case .idle: "idle"
            case .connecting(.handshaking): "connecting.handshaking"
            case .connecting(.checkingBackend): "connecting.checkingBackend"
            case .connecting(.needsDaemonUpdate): "connecting.needsDaemonUpdate"
            case .connecting(.backendUnavailable): "connecting.backendUnavailable"
            case .connecting(.failed): "connecting.failed"
            case .connected: "connected"
            case .unreachable: "unreachable"
            }
        }

        var robotName: String? {
            switch self {
            case let .connected(identity), let .unreachable(identity): identity.name
            case .idle, .connecting: nil
            }
        }
    }
#endif
