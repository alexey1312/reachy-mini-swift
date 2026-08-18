import Foundation
@testable import ReachyKit
@testable import ReachyUI
import Testing

/// The console exists for a robot nothing else can reach, so the parts that matter are
/// the ones that decide whether a root script goes out at all.
@MainActor
@Suite("BLE recovery console", .timeLimit(.minutes(1)))
struct BLEConsoleModelTests {
    private func linkedModel(_ transport: StubBLETransport) async -> BLEConsoleModel {
        let model = BLEConsoleModel { BLELink(transport: transport) }
        model.startScan()
        await model.connect(to: UUID())
        return model
    }

    @Test("the scripts come from the robot, and are readable before the code is given")
    func readsTheScriptListOffTheRobot() async {
        let transport = StubBLETransport(availableCommands: "RESTART_DAEMON, MYSTERY_SCRIPT")

        let model = await linkedModel(transport)

        // Still locked: the characteristic needs no session, and a code asked for in
        // front of an empty page tells the user nothing about whether it is worth it.
        #expect(model.stage == .locked)
        #expect(model.scripts.map(\.name) == ["RESTART_DAEMON", "MYSTERY_SCRIPT"])
        #expect(model.scripts.last?.severity == .disruptive)
    }

    @Test("the code is needed again after every script — the robot drops its own session")
    func relocksAfterEveryScript() async {
        let transport = StubBLETransport()
        let model = await linkedModel(transport)
        model.pinInput = transport.pin
        await model.submitPIN()
        #expect(model.stage == .unlocked)

        await model.run(BLERecoveryScript.describing("RESTART_DAEMON"))

        #expect(model.stage == .locked)
        #expect(transport.writtenCommands.contains("CMD_RESTART_DAEMON"))
    }

    @Test("a guarded run sends nothing at all when the code is wrong")
    func refusesAGuardedRunWithoutTheCode() async {
        let transport = StubBLETransport()
        let model = await linkedModel(transport)
        model.pinInput = transport.pin
        await model.submitPIN()

        let sent = await model.runGuarded(BLERecoveryScript.describing("SOFTWARE_RESET"), code: "00000")

        #expect(sent == false)
        #expect(transport.writtenCommands.contains { $0.hasPrefix("CMD_") } == false)
        // The re-check itself burns an attempt, which is the robot's counter, not ours.
        #expect(model.attemptsBeforeLockout == BLEPinSession.freeAttempts - 1)
    }

    @Test("the right code sends the script, once")
    func dispatchesAGuardedRun() async {
        let transport = StubBLETransport()
        let model = await linkedModel(transport)

        let sent = await model.runGuarded(BLERecoveryScript.describing("SOFTWARE_RESET"), code: transport.pin)

        #expect(sent)
        #expect(transport.writtenCommands.filter { $0 == "CMD_SOFTWARE_RESET" }.count == 1)
    }

    @Test("the journal reads without the code, because a robot too broken to unlock still logs")
    func tailsTheJournalWhileLocked() async {
        let transport = StubBLETransport()
        transport.journalChunks = ["hello\nwor"]
        let model = await linkedModel(transport)

        #expect(model.stage == .locked)
        await waitUntil("a whole line arrives") { !model.log.entries.isEmpty }
        #expect(model.log.entries.map(\.text) == ["hello"])
    }

    @Test("a journal that dies is started again rather than written off")
    func respawnsAJournalThatExited() async {
        let transport = StubBLETransport()
        transport.journalChunks = ["first\n"]
        // The robot's journalctl closes its pipe, its GLib watch removes itself, and the
        // next read answers "Journal not running". A fresh JOURNAL_START fixes it.
        transport.journalStopsAfter = 1
        let model = await linkedModel(transport)

        await waitUntil("the feed is restarted") { transport.journalStartCount >= 2 }

        transport.journalChunks = ["second\n"]

        await waitUntil("it delivers again") { model.log.entries.count >= 2 }
        #expect(model.journalFailure == nil)
        #expect(model.log.entries.map(\.text) == ["first", "second"])
    }
}
