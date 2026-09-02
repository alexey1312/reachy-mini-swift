import Foundation
import ReachyDesign
import ReachyKit
@testable import ReachyUI
import Testing

/// The dialogs capture as nothing, so their words are asserted here — the same
/// arrangement `RobotPowerOffModelTests` makes for the power-off dialog.
@Suite("Confirmation copy")
@MainActor
struct ConfirmationCopyTests {
    @Test("forgetting a network names it")
    func networkForgetNamesTheNetwork() {
        let confirmation = WiFiSettingsModel.forgetConfirmation(for: "Home")
        #expect(String(localized: confirmation.message).contains("Home"))
        #expect(String(localized: confirmation.confirm) == String(localized: .reachy("Forget")))
    }

    @Test("forgetting a robot names it and spares the robot")
    func robotForgetNamesTheRobot() {
        let entry = KnownRobotsModel.Entry(
            robot: KnownRobot(
                key: "abc",
                name: "Kitchen",
                address: RobotAddress(host: "10.0.0.7"),
                lastConnected: .now
            ),
            status: .checking
        )
        let confirmation = KnownRobotsModel.forgetConfirmation(for: entry)
        #expect(String(localized: confirmation.message).contains("Kitchen"))
        #expect(String(localized: confirmation.title) == String(localized: .reachy("Forget this robot?")))
    }

    @Test("a nameless robot is named by its address")
    func robotForgetFallsBackToTheAddress() {
        let entry = KnownRobotsModel.Entry(
            robot: KnownRobot(key: "abc", address: RobotAddress(host: "10.0.0.7"), lastConnected: .now),
            status: .checking
        )
        #expect(String(localized: KnownRobotsModel.forgetConfirmation(for: entry).message).contains("10.0.0.7"))
    }

    @Test("clearing the log counts what goes")
    func clearCountsTheLines() {
        let model = LogConsoleModel()
        model.ingest("one\ntwo\nthree\n")
        #expect(String(localized: model.clearConfirmation.message).hasPrefix("\(model.entries.count) "))
        #expect(model.entries.count == 3)
    }

    @Test("signing out says what becomes unreachable")
    func signOutNamesTheCost() {
        let confirmation = HFSignInModel.signOutConfirmation
        #expect(String(localized: confirmation.confirm) == String(localized: .reachy("Sign out")))
        #expect(
            String(localized: confirmation.message)
                ==
                String(
                    localized: .reachy(
                        "Your Reachies and private Spaces stay out of reach until you sign in again."
                    )
                )
        )
    }
}
