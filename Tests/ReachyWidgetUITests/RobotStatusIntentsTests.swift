import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// These two intents are the only ones that never reach a robot, so everything
/// they can get wrong is a wording decision. The one that matters: `isAwake` is
/// false for a parked robot *and* for a torn-down backend, and a spoken sentence
/// is the whole answer somebody gets — so it may not pick one of the two.
@Suite("Robot status intents")
struct RobotStatusIntentsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        robotID: String? = "hw-1",
        name: String? = "kitchen",
        isAwake: Bool = true,
        runningApp: String? = nil,
        runningAppName: String? = nil,
        failedApp: RobotSnapshot.FailedApp? = nil,
        appAgeInMinutes: Double = 0,
        ageInMinutes: Double = 0
    ) -> RobotSnapshot {
        let sawAnApp = runningApp != nil || runningAppName != nil || failedApp != nil
        return RobotSnapshot(
            robotID: robotID,
            robotName: name,
            isAwake: isAwake,
            runningApp: runningApp,
            runningAppName: runningAppName,
            failedApp: failedApp,
            runningAppTakenAt: sawAnApp ? now.addingTimeInterval(-appAgeInMinutes * 60) : nil,
            takenAt: now.addingTimeInterval(-ageInMinutes * 60)
        )
    }

    /// The catalogue carries no translations, so a resource resolves to its own key
    /// with the arguments substituted — which is exactly the English sentence.
    private func resolve(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }

    private func power(_ reading: RobotStatusReport.Reading) -> String {
        resolve(RobotStatusReport(reading: reading, at: now).powerDialog)
    }

    /// Identity by default, so a test only opts into the entry-point join when it
    /// is what is being measured.
    private func app(
        _ reading: RobotStatusReport.Reading,
        title: @escaping (String) -> String = { $0 }
    ) -> String {
        resolve(RobotStatusReport(reading: reading, at: now).appDialog(title: title))
    }

    // MARK: - Power

    @Test("a fresh awake reading is stated in the present tense")
    func speaksAnAwakeRobot() {
        let dialog = power(.current(snapshot()))

        #expect(dialog.contains("kitchen"))
        #expect(dialog.localizedCaseInsensitiveContains("is awake"))
        #expect(dialog.localizedCaseInsensitiveContains("not awake") == false)
    }

    /// **The rule the issue asked for.** A false `isAwake` has two causes with
    /// opposite ways out — parked motors are a mode, a stopped backend is a 90 s
    /// job — and the snapshot holds one bit. Naming only "asleep" sends somebody to
    /// a wake button that can only answer 503.
    @Test("a robot that is not awake is never reported as merely asleep")
    func refusesToChooseBetweenAsleepAndOffline() {
        let dialog = power(.current(snapshot(isAwake: false)))

        #expect(dialog.localizedCaseInsensitiveContains("not awake"))
        #expect(dialog.localizedCaseInsensitiveContains("backend"))
    }

    /// Past `RobotSnapshotStore.freshness` nothing has said the robot is still
    /// there. Repeating the last reading in the present tense is the one failure
    /// this whole type exists to prevent.
    @Test("a stale reading says when it last answered, never what it is doing")
    func refusesToStateAStaleReading() {
        let dialog = power(.remembered(snapshot(ageInMinutes: 90)))

        #expect(dialog.localizedCaseInsensitiveContains("is awake") == false)
        #expect(dialog.localizedCaseInsensitiveContains("asleep") == false)
        #expect(dialog.localizedCaseInsensitiveContains("not answered"))
    }

    @Test("with no robot at all it points at the app rather than describing one")
    func speaksTheEmptyState() {
        let dialog = power(.noRobot)

        #expect(dialog.localizedCaseInsensitiveContains("awake") == false)
        #expect(dialog.localizedCaseInsensitiveContains("no robot"))
    }

    /// Daemon 1.9.0 mounts no rename route, so an unnamed robot is ordinary. It
    /// still has to be called something.
    @Test("an unnamed robot is spoken as the product rather than as a blank")
    func namesAnUnnamedRobot() {
        let dialog = power(.current(snapshot(name: nil)))

        #expect(dialog.localizedCaseInsensitiveContains("reachy mini"))
    }

    // MARK: - Running app

    @Test("a running app displaces the power state")
    func speaksTheRunningApp() {
        let dialog = app(.current(snapshot(runningApp: "Dance Party", runningAppName: "dance_party")))

        #expect(dialog.contains("Dance Party"))
        #expect(dialog.contains("dance_party") == false)
    }

    /// `AppManager.start_app` files a status with an empty `extra`, so a snapshot
    /// written by an intent carries the Python entry point and no title at all.
    /// Speaking that is how Siri ends up saying `dance_party`.
    @Test("an entry point with no title is joined through the installed list")
    func joinsATitlelessRunningApp() {
        let dialog = app(
            .current(snapshot(runningAppName: "dance_party")),
            title: { $0 == "dance_party" ? "Dance Party" : $0 }
        )

        #expect(dialog.contains("Dance Party"))
    }

    /// The join is a lookup that can miss — a local app with no Hub card is still
    /// an app — and a slug is a better answer than somebody else's title.
    @Test("an entry point the cache does not know is spoken as it is")
    func keepsAnUnmatchedEntryPoint() {
        let dialog = app(.current(snapshot(runningAppName: "my_local_app")))

        #expect(dialog.contains("my_local_app"))
    }

    @Test("an idle awake robot says so rather than naming nothing")
    func speaksAnIdleRobot() {
        let dialog = app(.current(snapshot()))

        #expect(dialog.localizedCaseInsensitiveContains("not running an app"))
    }

    @Test("an app that died is named instead of the power state")
    func speaksACrash() {
        let failed = RobotSnapshot.FailedApp(name: "dance_party", title: "Dance Party", error: "exit 1")
        let dialog = app(.current(snapshot(failedApp: failed)))

        #expect(dialog.contains("Dance Party"))
        #expect(dialog.localizedCaseInsensitiveContains("stopped"))
    }

    /// A crash is a fact about a moment and nothing will ever arrive to contradict
    /// it, so it has its own much shorter window — `failureFreshness`, fifteen
    /// minutes. Past it the robot is described, not this morning's traceback.
    @Test("a crash past its window is no longer spoken")
    func retiresAnOldCrash() {
        let failed = RobotSnapshot.FailedApp(name: "dance_party", title: "Dance Party")
        let age = RobotSnapshotStore.failureFreshness / 60 + 1
        let dialog = app(.current(snapshot(failedApp: failed, appAgeInMinutes: age)))

        #expect(dialog.contains("Dance Party") == false)
        #expect(dialog.localizedCaseInsensitiveContains("not running an app"))
    }

    /// The error is a stderr *tail* — uvicorn's logging interleaved with a Python
    /// traceback. Readable on a screen, unspeakable.
    @Test("a crash speaks the app and not the traceback")
    func keepsTheTracebackOutOfTheDialog() {
        let failed = RobotSnapshot.FailedApp(
            name: "dance_party",
            title: "Dance Party",
            error: "Process exited with code 1\nModuleNotFoundError: no module named 'x'"
        )
        let dialog = app(.current(snapshot(failedApp: failed)))

        #expect(dialog.contains("ModuleNotFoundError") == false)
    }

    // MARK: - Which robot the reading belongs to

    /// **There is one snapshot and it belongs to whichever robot the app last
    /// talked to.** Reporting it under a name the caller supplied is how "is the
    /// *other* Reachy awake" gets a confident answer about this one.
    @Test("a named robot the snapshot does not describe gets no answer about it")
    func refusesAnotherRobotsReading() {
        let state = RobotSnapshotState.fresh(snapshot(robotID: "hw-1"))

        let report = RobotStatusDialog.report(state, for: "hw-2", at: now)

        #expect(report.reading == .noRobot)
    }

    @Test("a named robot the snapshot does describe is answered normally")
    func acceptsTheNamedRobotsReading() {
        let reading = snapshot(robotID: "hw-1")

        let report = RobotStatusDialog.report(.fresh(reading), for: "hw-1", at: now)

        #expect(report.reading == .current(reading))
    }

    /// Naming no robot means "whichever one this is", which is what the widget's
    /// own buttons mean and what every existing phrase resolves to.
    @Test("naming no robot takes the reading whatever robot it came from")
    func acceptsAnyReadingWhenNoRobotIsNamed() {
        let reading = snapshot(robotID: "hw-9")

        let report = RobotStatusDialog.report(.fresh(reading), for: nil, at: now)

        #expect(report.reading == .current(reading))
    }

    /// A snapshot written before identity was persisted matches no named robot.
    /// Saying nothing is the safe way to be wrong; the alternative is a sentence
    /// about a robot that may be somewhere else entirely.
    @Test("a snapshot with no identity answers no named robot")
    func refusesAnIdentitylessReadingForANamedRobot() {
        let state = RobotSnapshotState.fresh(snapshot(robotID: nil))

        let report = RobotStatusDialog.report(state, for: "hw-1", at: now)

        #expect(report.reading == .noRobot)
    }

    /// Stale survives the robot check as *stale*, rather than being flattened into
    /// "no reading at all" — the two are different answers, which is why this does
    /// not go through `freshReading(for:)`.
    @Test("a stale reading for the named robot stays stale rather than becoming nothing")
    func keepsStalenessApartFromAbsence() {
        let reading = snapshot(robotID: "hw-1", ageInMinutes: 90)

        let report = RobotStatusDialog.report(.stale(reading), for: "hw-1", at: now)

        #expect(report.reading == .remembered(reading))
    }
}
