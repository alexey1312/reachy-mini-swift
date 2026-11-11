import Foundation
import ReachyIntrospection
@testable import ReachyKit
import ReachySimulator
@testable import ReachyUI
import Testing

/// The connect gate and the shell as the introspection tree shows them
/// (`docs/adr/0007-introspection-tree.md`).
///
/// The journey test is a behavior test in Reflex's sense: it sees state and
/// actions only, and the session, the simulator and the router are the real ones.
@MainActor
@Suite("Introspection: gate and shell", .timeLimit(.minutes(1)))
struct IntrospectionGateTests {
    @MainActor
    private struct App {
        let session = RobotSession { _ in PreviewRobotClient() }
        let router = ReachyRouter()
        let progress = ConnectProgressModel(dwell: .zero)
        let registry = IntrospectionRegistry()
        let gate: ConnectGateModel
        let tree: IntrospectionTree

        init(address: String = "") {
            gate = ConnectGateModel(session: session, browser: RobotBrowser(), manualInput: address)
            registry.gate = gate
            tree = AppIntrospection.tree(session: session, router: router, progress: progress, registry: registry)
        }

        var actions: [String] {
            tree.snapshot().actions.map(\.name)
        }
    }

    @Test("an agent walks from the gate through the simulator to a tab, with no socket and no screen")
    func journey() async throws {
        let app = App()
        #expect(app.tree.snapshot().path == ["App", "ConnectGate"])
        #expect(app.actions.contains("startSimulator") == false)

        _ = try await app.tree.perform("toggleDeveloper")
        _ = try await app.tree.perform("startSimulator")

        // `ConnectionScreen` hands each phase to the progress model in an `onChange`.
        // No view is mounted here, so the test does that one line of wiring.
        await waitUntil("the shell is the focused node") {
            app.progress.observe(app.session.phase)
            return app.tree.snapshot().path == ["App", "Shell"]
        }
        #expect(app.tree.snapshot().state["tab"] == .string("robot"))

        let settings = try await app.tree.perform("selectTab", input: .object(["tab": .string("settings")]))
        #expect(settings.state["tab"] == .string("settings"))
        #expect(app.router.tab == .settings)
        app.session.disconnect()
    }

    @Test("every control a flow selects by identifier has an action, and the gate offers it")
    func coversTheIdentifiedControls() async throws {
        #expect(Set(ConnectGateModel.actionForControl.keys) == Set(AccessibilityID.allCases))

        // An address that parses and an open disclosure: the state that enables all five.
        let app = App(address: "192.168.1.42")
        _ = try await app.tree.perform("toggleDeveloper")

        let missing = Set(ConnectGateModel.actionForControl.values).subtracting(app.actions)
        #expect(missing.isEmpty)
    }

    @Test("an action is offered under the condition that enables its control")
    func followsTheScreen() async throws {
        let app = App()
        // An empty field: the Connect button is disabled.
        #expect(app.actions.contains("submit") == false)

        let typed = try await app.tree.perform("setAddress", input: .object(["text": .string("reachy.local")]))
        #expect(typed.state["addressIsValid"] == .bool(true))
        #expect(typed.actions.map(\.name).contains("submit"))

        // The Remote segment has no address field.
        let remote = try await app.tree.perform("selectRoute", input: .object(["route": .string("account")]))
        #expect(remote.actions.map(\.name).contains("setAddress") == false)
        #expect(remote.actions.map(\.name).contains("showRemoteRobots"))
    }

    @Test("a sheet takes the focus, and the gate's actions wait under it")
    func sheetCoversTheGate() async throws {
        let app = App()

        let sheet = try await app.tree.perform("showPermissions")
        #expect(sheet.path == ["App", "Permissions"])
        #expect(sheet.actions.map(\.name) == ["close"])
        await #expect(throws: IntrospectionError.self) {
            try await app.tree.perform("toggleDeveloper")
        }

        let closed = try await app.tree.perform("close")
        #expect(closed.path == ["App", "ConnectGate"])
    }

    @Test("Bluetooth setup is a node over the gate")
    func bluetoothSetup() async throws {
        let app = App()

        let setup = try await app.tree.perform("openBluetoothSetup")
        #expect(setup.path == ["App", "ConnectGate", "BluetoothSetup"])

        _ = try await app.tree.perform("close")
        #expect(app.gate.showsOnboarding == false)
    }

    @Test("an unknown tab is refused with the list of tabs")
    func refusesAnUnknownTab() async {
        let app = App()
        app.progress.observe(.connected(.preview))
        let response = await AppIntrospection.tree(
            session: .preview(),
            router: app.router,
            progress: app.progress,
            registry: app.registry
        ).respond(to: IntrospectionRequest(cmd: .perform, action: "selectTab", input: .object(["tab": .string("x")])))

        #expect(response.ok == false)
        #expect(response.error?.contains("the tabs are robot, live, moves, apps, settings") == true)
    }

    @Test("the server starts for --reachy-introspect with a port, and for nothing else")
    func readsThePort() {
        #expect(RootIntrospection.port(in: ["ReachyMini", "--reachy-introspect", "8765"]) == 8765)
        #expect(RootIntrospection.port(in: ["ReachyMini", "--reachy-smoke"]) == nil)
        #expect(RootIntrospection.port(in: ["ReachyMini", "--reachy-introspect"]) == nil)
        #expect(RootIntrospection.port(in: ["ReachyMini", "--reachy-introspect", "robot"]) == nil)
    }
}
