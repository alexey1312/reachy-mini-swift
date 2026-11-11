#if DEBUG
    import Foundation
    import ReachyIntrospection
    import ReachyKit

    extension ReachyRouter {
        private struct ShellState: Encodable {
            let tab: String
            let tabs: [String]
            let phase: String
            let robot: String?
        }

        private struct TabInput: Decodable {
            let tab: String
        }

        /// The five tabs. The screens inside them have no nodes yet, so the shell is
        /// the focused node on every tab and `selectTab` is its own action.
        func shellNode(session: RobotSession) -> IntrospectionNode {
            IntrospectionNode(
                name: "Shell",
                state: .state(ShellState(
                    tab: tab.rawValue,
                    tabs: Tab.allCases.map(\.rawValue),
                    phase: session.phase.introspectionName,
                    robot: session.phase.robotName
                )),
                actions: [
                    IntrospectionAction("selectTab", input: ["tab": .string]) { [self] input in
                        let name = try input.decode(TabInput.self).tab
                        guard let tab = Tab(rawValue: name) else {
                            let known = Tab.allCases.map(\.rawValue).joined(separator: ", ")
                            throw IntrospectionError.invalidRequest("no tab '\(name)'; the tabs are \(known)")
                        }
                        self.tab = tab
                    },
                ]
            )
        }

        /// The sheet the root presents, if one is up. `RootSheets` mounts the three.
        var sheetNode: IntrospectionNode? {
            if showsAccount {
                IntrospectionNode(
                    name: "Account",
                    actions: [IntrospectionAction("close") { [self] in showsAccount = false }]
                )
            } else if showsRemoteRobots {
                IntrospectionNode(
                    name: "RemoteRobots",
                    actions: [IntrospectionAction("close") { [self] in showsRemoteRobots = false }]
                )
            } else if showsPermissions {
                IntrospectionNode(
                    name: "Permissions",
                    actions: [IntrospectionAction("close") { [self] in showsPermissions = false }]
                )
            } else {
                nil
            }
        }
    }
#endif
