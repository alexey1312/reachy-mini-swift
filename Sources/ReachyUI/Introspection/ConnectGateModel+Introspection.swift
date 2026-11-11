#if DEBUG
    import Foundation
    import ReachyIntrospection
    import ReachyKit

    extension ConnectGateModel {
        /// The action behind each control the Maestro flows select by identifier.
        /// `IntrospectionGateTests` holds this to `AccessibilityID.allCases`, so a
        /// control that gets an identifier and no action fails a test.
        static let actionForControl: [AccessibilityID: String] = [
            .connectAddress: "setAddress",
            .connectSubmit: "submit",
            .connectBluetoothSetup: "openBluetoothSetup",
            .connectDeveloper: "toggleDeveloper",
            .connectStartSimulator: "startSimulator",
        ]

        private struct GateState: Encodable {
            struct Robot: Encodable {
                let id: String
                let name: String
                let address: String
                let status: String
            }

            struct Service: Encodable {
                let id: String
                let name: String
                let hardwareID: String?
            }

            let phase: String
            let displayedPhase: String
            let detail: String?
            let route: String
            let address: String
            let addressIsValid: Bool
            let showsDeveloper: Bool
            let awaitedHardwareID: String?
            let resolving: String?
            let knownRobots: [Robot]
            let discovered: [Service]
            let localNetworkDenied: Bool
            let error: String?
            let simulatorError: String?
        }

        private struct TextInput: Decodable {
            let text: String
        }

        private struct RouteInput: Decodable {
            let route: String
        }

        private struct IDInput: Decodable {
            let id: String
        }

        /// The gate as `ConnectionScreen` draws it.
        ///
        /// Each action is offered under the condition that enables its control on
        /// the screen, and calls what the control calls. The conditions are written
        /// a second time here, and that is the cost of a node: change a `disabled`
        /// on the screen and change the matching line here.
        ///
        /// Three things on the screen have no action yet: Forget, whose confirmation
        /// is `@State` of `NetworkRobotsSection`; the row for a daemon on this Mac;
        /// and `DaemonUpdateScreen`, which replaces the form while the phase is
        /// `needsDaemonUpdate`. The node offers nothing in that phase.
        func introspectionNode(progress: ConnectProgressModel, router: ReachyRouter) -> IntrospectionNode {
            IntrospectionNode(
                name: "ConnectGate",
                state: .state(state(progress: progress)),
                actions: actions(router: router),
                child: { [self] in
                    showsOnboarding
                        ? IntrospectionNode(
                            name: "BluetoothSetup",
                            actions: [IntrospectionAction("close") { [self] in showsOnboarding = false }]
                        )
                        : nil
                }
            )
        }

        private func state(progress: ConnectProgressModel) -> GateState {
            GateState(
                phase: session.phase.introspectionName,
                displayedPhase: progress.displayed.introspectionName,
                detail: detail,
                route: route.rawValue,
                address: manualInput,
                addressIsValid: RobotAddress(parsing: manualInput) != nil,
                showsDeveloper: showsDeveloper,
                awaitedHardwareID: awaitedHardwareID,
                resolving: resolving,
                knownRobots: (knownRobots?.entries ?? []).map { entry in
                    .init(
                        id: entry.id,
                        name: entry.displayName,
                        address: entry.robot.address.displayString,
                        status: String(describing: entry.status)
                    )
                },
                discovered: browser.services.map { .init(id: $0.id, name: $0.name, hardwareID: $0.hardwareID) },
                localNetworkDenied: browser.permissionLooksDenied,
                // The condition `ConnectionScreen.errorSection` shows it under.
                error: session.automaticConnectionAllowed ? nil : session.robotError,
                simulatorError: simulatorError
            )
        }

        private var detail: String? {
            switch session.phase {
            case let .connecting(.failed(_, message)): message
            case let .connecting(.backendUnavailable(_, daemonMessage)): daemonMessage
            default: nil
            }
        }

        private func actions(router: ReachyRouter) -> [IntrospectionAction] {
            if case .connecting(.needsDaemonUpdate) = session.phase {
                return []
            }
            return headerActions + formActions(router: router) + [
                IntrospectionAction("showPermissions") { router.showsPermissions = true },
                IntrospectionAction("showAccount") { router.showsAccount = true },
            ]
        }

        /// `ConnectHeader.actions`, branch for branch.
        private var headerActions: [IntrospectionAction] {
            guard session.powerTransition == nil else { return [] }
            let cancel = IntrospectionAction("cancel") { [session] in session.disconnect() }
            switch session.phase {
            case .connecting(.backendUnavailable):
                return [
                    IntrospectionAction("startBackend") { [session] in Task { await session.startBackend() } },
                    IntrospectionAction("continueAnyway") { [session] in session.proceedWithoutBackend() },
                    cancel,
                ]
            case .connecting(.failed):
                guard case let .lan(address) = session.link else { return [cancel] }
                return [
                    IntrospectionAction("tryAgain") { [session] in Task { await session.connect(to: address) } },
                    cancel,
                ]
            default:
                return []
            }
        }

        private func formActions(router: ReachyRouter) -> [IntrospectionAction] {
            let accepts = session.phase.acceptsConnectionChoice
            var actions = [IntrospectionAction("openBluetoothSetup") { [self] in showsOnboarding = true }]
            if accepts {
                actions.append(IntrospectionAction("selectRoute", input: ["route": .string]) { [self] input in
                    let name = try input.decode(RouteInput.self).route
                    guard let route = ConnectRoute(rawValue: name) else {
                        let known = ConnectRoute.allCases.map(\.rawValue).joined(separator: ", ")
                        throw IntrospectionError.invalidRequest("no route '\(name)'; the routes are \(known)")
                    }
                    self.route = route
                })
            }
            switch route {
            case .local where accepts:
                actions += localActions
            case .account:
                actions.append(IntrospectionAction("showRemoteRobots") { router.showsRemoteRobots = true })
            case .local:
                break
            }
            actions.append(IntrospectionAction("toggleDeveloper") { [self] in showsDeveloper.toggle() })
            if showsDeveloper, accepts {
                actions.append(IntrospectionAction("startSimulator") { [self] in connectToSimulator() })
            }
            return actions
        }

        /// The `Nearby` segment while a choice is accepted.
        private var localActions: [IntrospectionAction] {
            var actions: [IntrospectionAction] = []
            if let entries = knownRobots?.entries, !entries.isEmpty {
                actions.append(IntrospectionAction("connectKnown", input: ["id": .string]) { [self] input in
                    let id = try input.decode(IDInput.self).id
                    guard let entry = knownRobots?.entries.first(where: { $0.id == id }) else {
                        throw IntrospectionError.invalidRequest("no known robot '\(id)'")
                    }
                    connectManually(to: entry.robot.address)
                })
            }
            if !browser.services.isEmpty {
                actions.append(IntrospectionAction("connectDiscovered", input: ["id": .string]) { [self] input in
                    let id = try input.decode(IDInput.self).id
                    guard let service = browser.services.first(where: { $0.id == id }) else {
                        throw IntrospectionError.invalidRequest("no discovered robot '\(id)'")
                    }
                    connect(to: service)
                })
            }
            actions.append(IntrospectionAction("setAddress", input: ["text": .string]) { [self] input in
                manualInput = try input.decode(TextInput.self).text
            })
            if let address = RobotAddress(parsing: manualInput) {
                actions.append(IntrospectionAction("submit") { [self] in connectManually(to: address) })
            }
            return actions
        }
    }
#endif
