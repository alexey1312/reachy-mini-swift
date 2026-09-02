import XCTest

/// The only XCTest in the repository — XCUITest has no swift-testing form. What
/// these cover is the one thing snapshots cannot: the actual app binary booting,
/// with the @main wiring, the session construction and the shell's interaction.
///
/// Queries go by visible label, which `-testLanguage en` in the mise task pins —
/// the same trade the snapshot suite already made for its references.
final class SmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Tier 1, CI: launched frozen (`--reachy-smoke`, no Bonjour and no sockets)
    /// the connect gate stands, both route segments answer, the Bluetooth way out
    /// is offered, and the simulator is where the Developer disclosure puts it.
    ///
    /// The address field is asserted on the `Nearby` segment rather than behind one
    /// of its own — it moved under the robot list when the segments were shortened,
    /// which is the sort of change only this test and a reference image can see.
    func testColdLaunchShowsConnectGate() {
        let app = XCUIApplication()
        app.launchArguments += ["--reachy-smoke"]
        app.launch()

        let nearby = app.buttons["Nearby"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 30), "connect gate did not appear")
        XCTAssertTrue(app.textFields["host, host:port, or IP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Set up a new robot over Bluetooth"].waitForExistence(timeout: 5))

        app.buttons["Remote"].tap()
        nearby.tap()
        // Below the fold on a phone: a row that exists but is not on screen takes
        // a tap nowhere, so it is scrolled into view first.
        let developer = app.staticTexts["Developer"]
        XCTAssertTrue(developer.waitForExistence(timeout: 5), "Developer disclosure did not appear")
        var swipes = 0
        while !developer.isHittable, swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        developer.tap()
        let simulator = app.buttons["Start the simulator"]
        if !simulator.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(simulator.waitForExistence(timeout: 5), "simulator row did not open")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Tier 2, local: the whole user path against a live simulated daemon — a typed
    /// address, connect, and a tap through every tab. Gated on
    /// REACHY_SMOKE_HOST the way SimulatorIntegrationTests is on REACHY_SIM_HOST:
    /// a plain run skips it, `mise run test:smoke:sim` provides the host.
    func testConnectsToSimDaemonAndWalksTheTabs() throws {
        guard let host = ProcessInfo.processInfo.environment["REACHY_SMOKE_HOST"] else {
            throw XCTSkip("REACHY_SMOKE_HOST unset — start `mise run sim-daemon` and run `mise run test:smoke:sim`")
        }

        addUIInterruptionMonitor(withDescription: "Local Network permission") { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }

        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Nearby"].waitForExistence(timeout: 30), "connect gate did not appear")

        let field = app.textFields["host, host:port, or IP"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        clear(field, in: app)
        field.typeText(host)
        app.buttons["Connect"].tap()

        // The gate falls once the session settles; the sim daemon answers in
        // seconds, the ceiling only covers a cold CI-grade machine.
        let robotTab = app.tabBars.buttons["Robot"]
        XCTAssertTrue(robotTab.waitForExistence(timeout: 90), "five-tab shell did not appear")

        for tab in ["Live", "Moves", "Apps", "Settings", "Robot"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected, "tab \(tab) did not select")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// An empty field reports its placeholder as `value`, so deleting `value.count`
    /// characters blindly would type delete over nothing — harmless, but slow.
    private func clear(_ field: XCUIElement, in app: XCUIApplication) {
        guard let current = field.value as? String,
              !current.isEmpty,
              current != field.placeholderValue
        else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
}
