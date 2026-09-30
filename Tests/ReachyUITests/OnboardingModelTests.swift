import Foundation
@testable import ReachyKit
@testable import ReachyUI
import Testing

/// The flow's job is to get a robot from "no network at all" onto one, and then to hand
/// it over by identity — it is provisioned at one address and turns up at another.
///
/// `finish()` and `cancel()` also write to `UserDefaults`, which these tests deliberately
/// do not assert on: it is process-global state and `--parallel` runs suites at the same
/// time. What the caller actually acts on is the returned outcome.
@MainActor
@Suite("Onboarding flow", .timeLimit(.minutes(1)))
struct OnboardingModelTests {
    /// Generous on the deadline, tiny on the interval: the stub reports the join on the
    /// first poll, so nothing here waits out a duration.
    private static let patient = configuration(timeout: .seconds(10))
    /// Short enough that giving up is the thing being tested rather than a slow runner.
    private static let impatient = configuration(timeout: .milliseconds(200))

    private static func configuration(timeout: Duration) -> BLELink.Configuration {
        var configuration = BLELink.Configuration()
        configuration.joinTimeout = timeout
        configuration.joinPollInterval = .milliseconds(10)
        return configuration
    }

    private func makeModel(
        _ transport: StubBLETransport,
        configuration: BLELink.Configuration = OnboardingModelTests.patient
    ) -> OnboardingModel {
        OnboardingModel { BLELink(transport: transport, configuration: configuration) }
    }

    /// Walks up to the network step, which is where most of the interesting choices are.
    private func unlockedModel(
        _ transport: StubBLETransport,
        configuration: BLELink.Configuration = OnboardingModelTests.patient
    ) async -> OnboardingModel {
        let model = makeModel(transport, configuration: configuration)
        model.beginScan()
        await model.connect(to: UUID())
        model.pinInput = transport.pin
        await model.submitPIN()
        await model.skipName()
        return model
    }

    @Test("no Bluetooth session exists until the welcome screen has been left")
    func buildsTheSessionLate() {
        let model = makeModel(StubBLETransport())

        #expect(model.session == nil)
        #expect(model.availability == .unknown)

        model.beginScan()

        #expect(model.session != nil)
        #expect(model.step == .scan)
    }

    @Test("a wrong code stays put and reports how many tries are left")
    func countsDownFreeAttempts() async {
        let transport = StubBLETransport()
        let model = makeModel(transport)
        model.beginScan()
        await model.connect(to: UUID())
        #expect(model.step == .pin)

        model.pinInput = "00000"
        await model.submitPIN()

        #expect(model.step == .pin)
        #expect(model.attemptsBeforeLockout == BLEPinSession.freeAttempts - 1)
        #expect(model.errorMessage != nil)
    }

    /// The name comes while the PIN session is fresh — `SET_NAME` needs it, and the
    /// Wi-Fi step can outlast it.
    @Test("the right code opens the naming step")
    func namesStraightAfterUnlocking() async {
        let transport = StubBLETransport()
        let model = makeModel(transport)
        model.beginScan()
        await model.connect(to: UUID())
        model.pinInput = transport.pin

        await model.submitPIN()

        #expect(model.step == .name)
    }

    @Test("skipping the name opens the network step and asks the robot what it can see")
    func loadsNetworksAfterUnlocking() async {
        let transport = StubBLETransport()

        let model = await unlockedModel(transport)

        #expect(model.step == .network)
        #expect(model.networks == ["Home", "Cafe"])
        #expect(model.selectedSSID == "Home")
    }

    @Test("a name the robot takes moves on to the network")
    func namesTheRobot() async {
        let transport = StubBLETransport()
        transport.namesItself = true
        let model = makeModel(transport)
        model.beginScan()
        await model.connect(to: UUID())
        model.pinInput = transport.pin
        await model.submitPIN()

        model.nameInput = "  kitchen reachy "
        await model.submitName()

        #expect(transport.writtenCommands.contains("SET_NAME kitchen reachy"))
        #expect(model.step == .network)
        #expect(model.errorMessage == nil)
    }

    /// A 1.9.x robot echoes `SET_NAME`. Moving on as if the name had been taken would
    /// leave the reader looking for a robot under a name it never got.
    @Test("a robot that cannot be named over Bluetooth stays on the step and says so")
    func olderRobotSaysSo() async {
        let transport = StubBLETransport()
        let model = makeModel(transport)
        model.beginScan()
        await model.connect(to: UUID())
        model.pinInput = transport.pin
        await model.submitPIN()

        model.nameInput = "kitchen"
        await model.submitName()

        #expect(model.step == .name)
        #expect(model.nameIsUnsupported)

        await model.skipName()

        #expect(model.step == .network)
    }

    @Test("a name the daemon would refuse is not sent", arguments: ["", "   ", String(repeating: "r", count: 65)])
    func refusesAnImpossibleName(name: String) async {
        let transport = StubBLETransport()
        transport.namesItself = true
        let model = makeModel(transport)
        model.beginScan()
        await model.connect(to: UUID())
        model.pinInput = transport.pin
        await model.submitPIN()

        model.nameInput = name

        #expect(!model.canSubmitName)
        await model.submitName()
        #expect(!transport.writtenCommands.contains { $0.hasPrefix("SET_NAME") })
    }

    @Test("\"Other network…\" sends the name that was typed, not one off the truncated list")
    func sealsTheManuallyTypedNetwork() async {
        let transport = StubBLETransport()
        transport.networkStatusAfterJoin = "CONNECTED [wlan0] 192.168.1.42"
        let model = await unlockedModel(transport)

        model.selectedSSID = nil
        model.manualSSID = "Guest Wi-Fi"
        model.password = "hunter2"
        await model.join()

        let sealed = transport.writtenCommands.first { $0.hasPrefix("WIFI_CONNECT_ENC ") }
        #expect(sealed?.contains(#""ssid":"Guest Wi-Fi""#) == true)
        // The password is what the sealing exists to hide; it must never appear as itself.
        #expect(sealed?.contains("hunter2") == false)
    }

    @Test("a robot that never comes up gives up and keeps the password for another try")
    func keepsThePasswordAfterGivingUp() async {
        let transport = StubBLETransport()
        let model = await unlockedModel(transport, configuration: Self.impatient)

        model.password = "wrong-password"
        await model.join()

        #expect(model.joinState == .gaveUp)
        #expect(model.password == "wrong-password")

        model.editNetwork()

        #expect(model.step == .network)
    }

    @Test("a successful join carries the robot's new address into the handoff")
    func handsOverIdentityAndAddress() async {
        let transport = StubBLETransport(hardwareID: "a1b2c3d4e5f60718")
        transport.networkStatusAfterJoin = "CONNECTED [wlan0] 192.168.1.42"
        let model = await unlockedModel(transport)

        model.password = "hunter2"
        await model.join()

        #expect(model.joinState == .joined)
        // Cleared as soon as it is no longer needed: ADR 0001 leaves storing credentials
        // to a real pairing protocol.
        #expect(model.password.isEmpty)

        model.continueAfterJoin()
        #expect(model.step == .handoff)

        let outcome = model.finish()

        #expect(outcome.hardwareID == "a1b2c3d4e5f60718")
        #expect(outcome.address == RobotAddress(parsing: "192.168.1.42"))
    }

    @Test("a robot already on a network has nothing left to configure")
    func skipsAJoinThatAlreadyHappened() async {
        let transport = StubBLETransport(networkStatus: "CONNECTED [wlan0] 192.168.1.7")

        let model = await unlockedModel(transport)

        #expect(model.isAlreadyOnNetwork)

        model.skipNetwork()

        #expect(model.step == .handoff)
        #expect(model.finish().address == RobotAddress(parsing: "192.168.1.7"))
    }

    @Test("stepping back from the code screen drops the link the code belonged to")
    func dropsTheLinkOnTheWayBack() async {
        let transport = StubBLETransport()
        let model = makeModel(transport)
        model.beginScan()
        await model.connect(to: UUID())

        model.back()

        #expect(model.step == .scan)
        #expect(transport.disconnectCount == 1)
    }
}
