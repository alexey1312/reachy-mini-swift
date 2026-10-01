import Foundation
@testable import ReachyKit
@testable import ReachyUI
import Testing

/// A client with none of the capabilities the first run asks for, so a test can
/// watch a step fail the way a robot without them would.
private struct BareClient: RobotAPIClient {
    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: .preview, status: .preview())
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        .preview()
    }

    func wakeUp() async throws -> String {
        "wake"
    }

    func gotoSleep() async throws -> String {
        "sleep"
    }
}

/// The first run's model (#169): the order of the steps, what holds the wake-up, and
/// what each check concludes from what the robot said.
@MainActor
@Suite("First run model", .timeLimit(.minutes(1)))
struct FirstRunModelTests {
    private static let sleeping = SleepPosition.target

    private static func frame(_ joints: [Double] = sleeping) -> RobotStateFrame {
        RobotStateFrame(headJoints: Array(joints[0 ..< 7]), antennas: Array(joints[7 ..< 9]))
    }

    private static func frame(speech: Bool?) -> RobotStateFrame {
        RobotStateFrame(directionOfArrival: speech.map { .init(angle: 1.2, speechDetected: $0) })
    }

    private func session(
        awake: Bool = false,
        client: any RobotAPIClient = PreviewRemoteRobotClient()
    ) -> RobotSession {
        RobotSession.preview(
            status: .preview(motorMode: awake ? .enabled : .disabled),
            link: .remote,
            client: client
        )
    }

    /// Answers a scripted frame per call, then the last one for ever.
    @MainActor
    private final class Frames {
        var queue: [Result<RobotStateFrame?, any Error>]
        private(set) var reads = 0

        init(_ queue: [Result<RobotStateFrame?, any Error>]) {
            self.queue = queue
        }

        func next() throws -> RobotStateFrame? {
            reads += 1
            let result = queue.count > 1 ? queue.removeFirst() : queue[0]
            return try result.get()
        }
    }

    private func model(
        session: RobotSession,
        frames: Frames? = nil,
        rename: @escaping FirstRunModel.Rename = { _, name in name },
        wake: @escaping FirstRunModel.Power = { _ in },
        finish: @escaping FirstRunModel.Finish = { _ in }
    ) -> FirstRunModel {
        FirstRunModel(
            session: session,
            readPose: frames.map { frames in { @MainActor in try frames.next() } },
            rename: rename,
            wake: wake,
            finish: finish,
            pollInterval: .milliseconds(1)
        )
    }

    // MARK: - Steps

    @Test("the steps run in order, and each one closes the last one's note")
    func walksForward() {
        let model = model(session: session())
        var seen = [model.step]
        while model.step != .done {
            model.showHelp()
            model.advance()
            #expect(!model.needsHelp)
            seen.append(model.step)
        }
        model.advance()

        #expect(seen == FirstRunModel.Step.allCases)
        #expect(model.step == .done)
    }

    @Test("finishing hands the session to the finish call once")
    func finishes() async {
        let session = session()
        var finished: [ObjectIdentifier] = []
        let model = model(session: session, finish: { finished.append(ObjectIdentifier($0)) })

        await model.finish()

        #expect(finished == [ObjectIdentifier(session)])
    }

    // MARK: - Name

    /// The robot already holds it, so asking it to store the same name buys nothing.
    @Test("keeping the robot's name moves on without renaming")
    func keepsTheName() async {
        var renamed: [String] = []
        let model = model(session: session(), rename: { _, name in
            renamed.append(name)
            return name
        })
        model.advance()
        model.nameInput = "  Reachy Mini "

        await model.saveName()

        #expect(renamed.isEmpty)
        #expect(model.step == .motors)
    }

    @Test("a new name is trimmed, stored and read back from the robot")
    func renames() async {
        var renamed: [String] = []
        let model = model(session: session(), rename: { _, name in
            renamed.append(name)
            return "kitchen"
        })
        model.advance()
        model.nameInput = "  Kitchen  "

        await model.saveName()

        #expect(renamed == ["Kitchen"])
        #expect(model.nameInput == "kitchen")
        #expect(model.step == .motors)
    }

    @Test("a refused name stays on the step and says why")
    func reportsARefusedName() async {
        let model = model(session: session(), rename: { _, _ in throw ReachyKitError.notConnected })
        model.advance()
        model.nameInput = "Kitchen"

        await model.saveName()

        #expect(model.step == .name)
        #expect(model.nameError != nil)
    }

    @Test("an empty or over-long name cannot be saved")
    func boundsTheName() {
        let model = model(session: session())
        model.nameInput = "   "
        #expect(!model.canSaveName)
        model.nameInput = String(repeating: "a", count: FirstRunModel.maximumNameLength)
        #expect(model.canSaveName)
        model.nameInput += "a"
        #expect(model.nameIsTooLong)
        #expect(!model.canSaveName)
    }

    // MARK: - Motors

    @Test("nothing wakes the robot before the motors have been read")
    func holdsTheWakeUntilRead() {
        #expect(!model(session: session()).canWake)
    }

    /// Two cables in each other's sockets read wrong while limp and drive each motor
    /// to the other's target once powered — the reason the check exists.
    @Test("a robot out of position cannot be woken, and one back in place can")
    func gatesTheWakeOnThePosition() async {
        var misplaced = Self.sleeping
        misplaced.swapAt(RobotMotor.neck2.rawValue, RobotMotor.neck5.rawValue)
        let frames = Frames([.success(Self.frame(misplaced))])
        let model = model(session: session(), frames: frames)

        let watching = Task { await model.watchPose() }
        await waitUntil("the check has read the motors") { model.poseCheck != .reading }
        #expect(!model.canWake)
        guard case let .checked(.outOfPosition(_, swaps)) = model.poseCheck else {
            Issue.record("expected the swap to be named: \(model.poseCheck)")
            return
        }
        #expect(swaps == [MotorSwap(.neck2, .neck5)])

        frames.queue = [.success(Self.frame())]
        await waitUntil("the robot is back in place") { model.canWake }
        watching.cancel()
        await watching.value
    }

    /// An older daemon sends no motor-by-motor pose, and a check that cannot read
    /// must not keep somebody on a screen they cannot pass.
    @Test("a robot that cannot report its motors does not hold the wake-up")
    func failsOpenWithoutData() async {
        let model = model(session: session(), frames: Frames([.success(RobotStateFrame(bodyYaw: 0))]))

        let watching = Task { await model.watchPose() }
        await waitUntil("the check has concluded") { model.poseCheck == .checked(.unavailable) }
        #expect(model.canWake)
        watching.cancel()
        await watching.value
    }

    @Test("reads that keep failing stop holding the wake-up; one that fails later changes nothing")
    func toleratesFailedReads() async {
        let failing = model(session: session(), frames: Frames([.failure(ReachyKitError.notConnected)]))
        let first = Task { await failing.watchPose() }
        await waitUntil("the check gives up") { failing.poseCheck == .checked(.unavailable) }
        first.cancel()
        await first.value

        let frames = Frames([.success(Self.frame()), .failure(ReachyKitError.notConnected)])
        let flaky = model(session: session(), frames: frames)
        let second = Task { await flaky.watchPose() }
        await waitUntil("the failure has been read past") { frames.reads >= FirstRunModel.unreadableFrames + 2 }
        #expect(flaky.poseCheck == .checked(.inPosition))
        second.cancel()
        await second.value
    }

    @Test("an awake robot is offered sleep, never a second wake-up")
    func doesNotWakeAnAwakeRobot() async {
        let model = model(session: session(awake: true), frames: Frames([.success(Self.frame())]))
        let watching = Task { await model.watchPose() }
        await waitUntil("the check has read the motors") { model.poseCheck != .reading }

        #expect(!model.canWake)
        watching.cancel()
        await watching.value
    }

    @Test("a wake that stood the robot up turns the step into a question, and stops the reading")
    func wakes() async {
        let session = session()
        var woken = 0
        let frames = Frames([.success(Self.frame())])
        let model = model(session: session, frames: frames, wake: { session in
            woken += 1
            session.lastStatus = .preview(motorMode: .enabled)
        })
        let watching = Task { await model.watchPose() }
        await waitUntil("the check has passed") { model.canWake }

        await model.wakeUp()
        await watching.value

        #expect(woken == 1)
        #expect(model.hasWoken)
    }

    @Test("a wake that left the robot asleep is not a wake")
    func noticesAFailedWake() async {
        let model = model(session: session(), frames: Frames([.success(Self.frame())]))
        let watching = Task { await model.watchPose() }
        await waitUntil("the check has passed") { model.canWake }

        await model.wakeUp()

        #expect(!model.hasWoken)
        watching.cancel()
        await watching.value
    }

    // MARK: - Microphone

    @Test("the robot reporting speech twice in a row is a robot that heard")
    func hears() async {
        let frames = Frames([
            .success(Self.frame(speech: true)),
            .success(Self.frame(speech: false)),
            .success(Self.frame(speech: true)),
            .success(Self.frame(speech: true)),
        ])
        let model = model(session: session(), frames: frames)

        await model.listen()

        #expect(model.hearing == .heard)
        #expect(frames.reads == 4)
    }

    /// No array, or firmware below 2.1.0: the daemon sends `doa: null` for ever.
    @Test("a robot that reports no direction at all cannot be checked")
    func givesUpOnASilentField() async {
        let frames = Frames([.success(Self.frame(speech: nil))])
        let model = model(session: session(), frames: frames)

        await model.listen()

        #expect(model.hearing == .unsupported)
        #expect(frames.reads == FirstRunModel.silentFrames)
    }

    @Test("with nothing to ask, there is nothing to listen for")
    func cannotListenWithoutAConnection() async {
        let model = model(session: session())

        await model.listen()

        #expect(model.hearing == .unsupported)
    }

    // MARK: - Speaker

    @Test("a test sound the robot accepted moves the step on to asking")
    func playsTheSound() async {
        let model = model(session: session())

        await model.playTestSound()

        #expect(model.hasPlayedSound)
        #expect(model.audio.errorMessage == nil)
    }

    @Test("a test sound the robot could not play says so and asks nothing")
    func reportsAFailedSound() async {
        let model = model(session: session(client: BareClient()))

        await model.playTestSound()

        #expect(!model.hasPlayedSound)
        #expect(model.audio.errorMessage != nil)
    }
}
