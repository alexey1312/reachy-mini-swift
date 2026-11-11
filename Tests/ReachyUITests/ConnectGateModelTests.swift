import Foundation
import Network
@testable import ReachyKit
import ReachySimulator
@testable import ReachyUI
import Testing

/// The gate's own state and actions, which were `@State` and private methods of
/// `ConnectionScreen` until the model took them. `start()` is not called here: it
/// starts Bonjour and reads the shared defaults.
@MainActor
@Suite("Connect gate", .timeLimit(.minutes(1)))
struct ConnectGateModelTests {
    private func model(
        session: RobotSession = RobotSession { _ in PreviewRobotClient() },
        makeSimulator: @escaping @MainActor () -> (any RobotAPIClient)? = { SimulatedRobotClient() },
        resolve: @escaping @MainActor (RobotBrowser.DiscoveredService) async -> RobotAddress? = { _ in nil }
    ) -> ConnectGateModel {
        ConnectGateModel(
            session: session,
            browser: RobotBrowser(),
            manualInput: "",
            makeSimulator: makeSimulator,
            resolve: resolve
        )
    }

    @Test("the simulator connects the session with no network")
    func simulatorConnects() async {
        let session = RobotSession { _ in PreviewRobotClient() }
        let model = model(session: session)

        model.connectToSimulator()

        await waitUntil("the session is connected") {
            if case .connected = session.phase {
                true
            } else {
                false
            }
        }
        #expect(model.simulatorError == nil)
        session.disconnect()
    }

    @Test("a simulator that cannot be built is reported, and the next good start clears the report")
    func simulatorFailureIsReported() async {
        var builds = false
        let session = RobotSession { _ in PreviewRobotClient() }
        let model = model(session: session, makeSimulator: { builds ? SimulatedRobotClient() : nil })

        model.connectToSimulator()
        #expect(model.simulatorError != nil)
        #expect(session.phase == .idle)

        builds = true
        model.connectToSimulator()
        #expect(model.simulatorError == nil)
        await waitUntil("the session is connected") {
            if case .connected = session.phase {
                true
            } else {
                false
            }
        }
        session.disconnect()
    }

    @Test("the end of Bluetooth setup closes the sheet and names the robot to wait for")
    func finishOnboarding() {
        let model = model()
        model.showsOnboarding = true

        model.finishOnboarding(OnboardingOutcome(hardwareID: "abc123", address: nil))

        #expect(model.showsOnboarding == false)
        #expect(model.awaitedHardwareID == "abc123")
    }

    @Test("a tapped Bonjour row shows its spinner until the resolve ends")
    func resolvingMarksTheRow() async {
        let session = RobotSession { _ in PreviewRobotClient() }
        let model = model(session: session)
        let service = RobotBrowser.DiscoveredService(
            name: "reachy-mini",
            type: "_reachy-mini._tcp",
            endpoint: .service(name: "reachy-mini", type: "_reachy-mini._tcp", domain: "local.", interface: nil)
        )

        model.connect(to: service)
        #expect(model.resolving == service.id)

        await waitUntil("the resolve ended") { model.resolving == nil }
        #expect(session.phase == .idle)
    }

    @Test("the gate gives way only when the rail has shown the connection")
    func releasesGate() {
        let identity = RobotIdentity.preview
        let progress = ConnectProgressModel(dwell: .zero)

        #expect(progress.releasesGate(for: .idle) == false)
        #expect(progress.releasesGate(for: .connecting(.handshaking)) == false)
        // The session is connected and the rail has not shown it yet.
        #expect(progress.releasesGate(for: .connected(identity)) == false)
        progress.observe(.connected(identity))
        #expect(progress.releasesGate(for: .connected(identity)))
        // A later network blip belongs to the shell, whatever the rail shows.
        #expect(ConnectProgressModel(dwell: .zero).releasesGate(for: .unreachable(identity)))
    }
}
