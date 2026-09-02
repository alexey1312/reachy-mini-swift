import ReachyDesign
import ReachyKit
@testable import ReachyUI
import Testing

@Suite("Recovery script captions")
struct BLERecoveryScriptCaptionTests {
    @Test("each known script is titled in words, and an unknown one by its file name")
    func scriptsHaveTitles() {
        let restart = BLERecoveryScript.describing("RESTART_DAEMON")
        let unknown = BLERecoveryScript.describing("FACTORY_WIPE")

        #expect(BLERecoveryScriptCaption
            .title(for: restart) == String(localized: .reachy("Restart the robot's software")))
        #expect(BLERecoveryScriptCaption.title(for: unknown) == "FACTORY_WIPE")
    }

    @Test("an unknown script is never described as harmless")
    func unknownScriptSummaryWarns() {
        let unknown = BLERecoveryScript.describing("FACTORY_WIPE")
        let expected = String(
            localized: .reachy("This app does not know what this script does. It runs as root on the robot.")
        )

        #expect(BLERecoveryScriptCaption.summary(for: unknown) == expected)
    }
}
