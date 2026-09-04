import XCTest

/// Drives the system Messages app to a conversation with the keyboard's sticker
/// browser open and **leaves it there**, so `xcrun simctl io <udid> screenshot` can
/// photograph real Messages chrome for the App Store listing's iMessage section.
///
/// It leaves the screen standing rather than taking an `XCTAttachment` on purpose:
/// an attachment has to be dug back out of the `.xcresult`, while a simulator simply
/// sitting on the right screen can be photographed by anything, at the device's own
/// native resolution, as many times as you like.
///
/// **The pack itself does not appear here, and that is the simulator's doing rather
/// than ours.** Two places were checked and both are empty of it: the "+" app drawer,
/// which since iOS 17 lists only Apple's own apps because a codeless pack belongs to
/// the Stickers browser instead, and the Stickers browser itself, which shows nothing
/// but its "Send stickers you make from photos, emoji, or your very own Memoji"
/// intro card. The extension is nonetheless installed and correctly registered —
/// `xcrun simctl spawn <udid> pluginkit -mAvv -p com.apple.message-payload-provider`
/// lists `com.alexey1312.ReachyMini.Stickers` with the right SDK, display name and
/// parent — so the missing piece is the simulator's `stickerd`, not the catalogue.
/// Confirm the drawer on hardware, through `mise run device`.
///
/// Gated on `REACHY_CAPTURE`, the way `SimulatorIntegrationTests` is gated on
/// `REACHY_SIM_HOST`: a plain `mise run test:smoke` must not start poking at
/// Messages. Run it through `mise run screenshots:capture`.
final class StickerCaptureTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testOpensTheStickerBrowserInMessages() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["REACHY_CAPTURE"] == "1",
            "set REACHY_CAPTURE=1 to drive Messages — see mise run screenshots:capture"
        )

        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        XCTAssertTrue(messages.wait(for: .runningForeground, timeout: 30), "Messages did not come up")

        // The simulator ships two seeded conversations; either will do as a stage.
        let conversation = messages.cells.firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 20), "no conversation to open")
        conversation.tap()

        // A first run offers the QuickPath tutorial over the keyboard.
        let carryOn = messages.buttons["Continue"]
        if carryOn.waitForExistence(timeout: 5) {
            carryOn.tap()
        }

        // The stickers live behind the emoji key rather than the "+".
        let emoji = messages.buttons["Emoji"].firstMatch
        XCTAssertTrue(emoji.waitForExistence(timeout: 10), "no emoji key on the keyboard")
        emoji.tap()

        // Leave it standing. The shell photographs it from here.
        sleep(3)
    }
}
