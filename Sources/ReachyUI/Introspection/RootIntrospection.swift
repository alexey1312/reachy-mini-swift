#if DEBUG
    import OSLog
    import ReachyIntrospection
    import ReachyKit
    import SwiftUI

    /// Serves the app's introspection tree for a run started with
    /// `--reachy-introspect <port>`, and for no other run.
    ///
    /// On the root for the reason `RootJSAppHost` is: the session, the router and
    /// the progress model are the root's, and the registry has to be in the
    /// environment of every screen below. `docs/adr/0007-introspection-tree.md`
    /// has the design, and `mise run introspect` is the client.
    ///
    /// The argument is its own, and `--reachy-smoke` does not imply it: that one
    /// stops every `onAppear` of the app, and a run an agent drives wants them.
    struct RootIntrospection: ViewModifier {
        let session: RobotSession
        let router: ReachyRouter
        let progress: ConnectProgressModel

        @State private var registry = IntrospectionRegistry()
        @State private var server: IntrospectionServer?

        private static let log = Logger(subsystem: "com.alexey1312.ReachyMini", category: "Introspection")

        func body(content: Content) -> some View {
            content
                .environment(\.reachyIntrospection, registry)
                .task {
                    guard server == nil, let port = Self.port(in: ProcessInfo.processInfo.arguments) else { return }
                    let server = IntrospectionServer(
                        tree: AppIntrospection.tree(
                            session: session,
                            router: router,
                            progress: progress,
                            registry: registry
                        )
                    )
                    self.server = server
                    do {
                        let bound = try await server.start(port: port)
                        Self.log.notice("The introspection tree is on 127.0.0.1:\(bound, privacy: .public)")
                    } catch {
                        Self.log.error("The introspection server did not start: \(String(describing: error))")
                    }
                }
        }

        /// The port that follows `--reachy-introspect`, or `nil` when the argument
        /// is absent or its value is not a port.
        static func port(in arguments: [String]) -> UInt16? {
            guard let flag = arguments.firstIndex(of: "--reachy-introspect"),
                  arguments.indices.contains(flag + 1)
            else { return nil }
            return UInt16(arguments[flag + 1])
        }
    }
#endif
