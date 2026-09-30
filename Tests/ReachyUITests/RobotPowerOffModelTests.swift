import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

@MainActor
@Suite("Power off")
struct RobotPowerOffModelTests {
    @Test("names the app the shutdown will take with it")
    func namesTheRunningApp() {
        let model = RobotPowerOffModel()
        let session = RobotSession.preview(runningApp: .preview(.running))
        #expect(model.runningApp(session)?.name == RobotAppStatus.preview(.running).app.name)
    }

    @Test("says nothing about an app that has already finished")
    func ignoresAFinishedApp() {
        let model = RobotPowerOffModel()
        #expect(model.runningApp(RobotSession.preview(runningApp: .preview(.done))) == nil)
        #expect(model.runningApp(RobotSession.preview(runningApp: .previewCrashed)) == nil)
        #expect(model.runningApp(RobotSession.preview()) == nil)
    }

    /// The same reading `RobotAppStatus.State.isBusy` takes: a state this client
    /// does not recognise still holds the robot, so it is still worth naming.
    @Test("an unfamiliar process state still counts as running")
    func unknownStateCountsAsRunning() {
        let model = RobotPowerOffModel()
        let status = RobotAppStatus(app: RobotApp.previewInstalled[0], state: .unknown("pausing"))
        #expect(model.runningApp(RobotSession.preview(runningApp: status)) != nil)
    }

    @Test("offered on a LAN session only — the relay has no route to the daemon's own stop")
    func relaySessionCannotPowerOff() {
        let model = RobotPowerOffModel()
        #expect(model.canPowerOff(RobotSession.preview()))
        #expect(!model.canPowerOff(RobotSession.preview(address: nil, link: .remote)))
    }

    @Test("declines a second tap while a transition is running")
    func busyDuringATransition() {
        let model = RobotPowerOffModel()
        #expect(!model.canPowerOff(RobotSession.preview(powerTransition: .stoppingBackend)))
        #expect(!model.canPowerOff(RobotSession.preview(powerTransition: .goingToSleep)))
    }

    // MARK: - An app set to start on wake-up

    /// The daemon only hears the antenna touch that starts that app while its
    /// backend runs, so the teardown becomes the second choice, not the only one.
    @Test("a startup app puts sleep first and the teardown second")
    func startupAppOffersSleepFirst() {
        let model = RobotPowerOffModel(startupApp: "dance")
        let session = RobotSession.preview()
        #expect(model.plan(session) == .sleep(keepingStartupApp: "dance"))
        #expect(model.offersSleep(session))
    }

    @Test("without a startup app the dialog is the one it always was")
    func noStartupAppIsTheOldDialog() {
        let model = RobotPowerOffModel()
        let session = RobotSession.preview()
        #expect(model.plan(session) == .stopBackend)
        #expect(!model.offersSleep(session))
        #expect(model.confirmationMessage(session)
            == String(localized: .reachy("The robot goes to sleep first, then its motors and camera shut down.")))
    }

    /// Already where the first choice would take it: Cancel says so, and the
    /// sleep animation would only play at limp motors.
    @Test("a robot already asleep is not offered sleep again")
    func asleepRobotIsNotOfferedSleep() {
        let model = RobotPowerOffModel(startupApp: "dance")
        let session = RobotSession.preview(status: .preview(motorMode: .disabled))
        #expect(model.plan(session) == .sleep(keepingStartupApp: "dance"))
        #expect(!model.offersSleep(session))
    }

    /// Nothing is left listening, and `goto_sleep` would answer 503.
    @Test("a backend that is already down gets the old dialog")
    func stoppedBackendIsTheOldDialog() {
        let model = RobotPowerOffModel(startupApp: "dance")
        let session = RobotSession.preview(status: .preview(state: .stopped))
        #expect(model.plan(session) == .stopBackend)
        #expect(!model.offersSleep(session))
    }

    @Test("the dialog says what powering off costs the startup app")
    func messageNamesTheAntennaCost() {
        let model = RobotPowerOffModel(startupApp: "dance")
        let cost = String(localized: .reachy(
            // swiftlint:disable:next line_length
            "Touching an antenna starts the app set to start on wake-up, and a sleeping robot still notices it. A powered-off one does not, until you wake it from here."
        ))
        #expect(model.confirmationMessage(RobotSession.preview()) == cost)

        let running = RobotSession.preview(runningApp: .preview(.running))
        let title = RobotAppStatus.preview(.running).app.title
        let message = model.confirmationMessage(running)
        #expect(message.hasPrefix(title))
        #expect(message.hasSuffix(cost))
    }

    @Test("reads the startup app from the robot")
    func refreshReadsTheStartupApp() async {
        let client = StoreRobotClient()
        client.startup = "dance"
        let session = RobotSession.preview(client: client)
        let model = RobotPowerOffModel()

        await model.refresh(session)
        #expect(model.startupApp == "dance")

        client.startup = nil
        await model.refresh(session)
        #expect(model.startupApp == nil)
    }

    /// `try?` would fold "no startup app" and "no answer" into the same nil, and a
    /// Wi-Fi blip would quietly make the teardown the only choice again.
    @Test("a read that fails keeps the last answer")
    func failedRefreshKeepsTheReading() async {
        let client = StoreRobotClient()
        client.startup = "dance"
        let session = RobotSession.preview(client: client)
        let model = RobotPowerOffModel()
        await model.refresh(session)

        client.failsStartupRead = true
        await model.refresh(session)
        #expect(model.startupApp == "dance")
    }
}
