import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The two presence switches, whose whole difficulty is that the robot will not say
/// what it is doing.
@MainActor
@Suite("Presence controls", .timeLimit(.minutes(1)))
struct PresenceModelTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var wobbling: [Bool] = []
        private(set) var tracking: [Bool] = []
        /// The weight each `setFaceTracking` carried, which is the whole of what the
        /// slider can be asserted on: no route reports it back.
        private(set) var weights: [Double] = []
        /// What the robot answers `setFaceTracking` with — false is a camera-less one.
        var trackingTakes = true
        /// What `/media/tracking/face` answers, and how often it has been asked.
        var face: RobotFaceTarget?
        var faceFailure: (any Error)?
        private(set) var faceReads = 0
        var failure: (any Error)?
        /// Holds `setWobbling` open so a second hand-off really does overlap the first.
        /// The latch is only reachable while a call is in flight, which a sequential
        /// test cannot arrange.
        var gate: Gate?

        func wobble(_ value: Bool) async throws {
            await gate?.wait()
            if let failure {
                throw failure
            }
            lock.withLock { wobbling.append(value) }
        }

        func track(_ value: Bool, weight: Double) throws -> Bool {
            if let failure {
                throw failure
            }
            lock.withLock {
                tracking.append(value)
                weights.append(weight)
            }
            return value && trackingTakes
        }

        func readFace() throws -> RobotFaceTarget? {
            lock.withLock { faceReads += 1 }
            if let faceFailure {
                throw faceFailure
            }
            return face
        }

        var faceReadCount: Int {
            lock.withLock { faceReads }
        }
    }

    /// Every waiter is resumed, never only the newest: a missing latch is meant to fail
    /// the count, not to strand nineteen continuations and hang the run instead.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                guard !isOpen else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiting.append(continuation)
                lock.unlock()
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let pending = waiting
            waiting = []
            lock.unlock()
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    private func model(_ calls: Calls) -> PresenceModel {
        PresenceModel(
            setWobbling: { _, value in try await calls.wobble(value) },
            setFaceTracking: { _, value, weight in try calls.track(value, weight: weight) },
            trackedFace: { _ in try calls.readFace() },
            // Small rather than zero: the loop must yield often enough for the test to
            // observe it, without spinning the one actor both of them run on.
            facePollInterval: .milliseconds(5)
        )
    }

    @Test("each switch reaches its own route")
    func sendsBoth() async {
        let calls = Calls()
        let model = model(calls)
        let session = RobotSession.preview()

        await model.setWobbling(true, session: session)
        await model.setFaceTracking(true, session: session)

        #expect(calls.wobbling == [true])
        #expect(calls.tracking == [true])
        #expect(model.isWobbling)
        #expect(model.isTracking)
    }

    /// A camera-less robot answers `enabled: false` under a 200. Leaving the switch
    /// on would claim a robot is watching when it is not — the one thing these
    /// controls must not do, since nothing else on screen could correct it.
    @Test("a robot that refuses tracking leaves the switch off, and says why")
    func reportsRefusedTracking() async {
        let calls = Calls()
        calls.trackingTakes = false
        let model = model(calls)

        await model.setFaceTracking(true, session: .preview())

        #expect(!model.isTracking)
        #expect(model.lastError != nil)
    }

    @Test("a failed call leaves the switch where it was")
    func keepsStateOnFailure() async {
        let calls = Calls()
        calls.failure = ReachyKitError.notConnected
        let model = model(calls)

        await model.setWobbling(true, session: .preview())

        #expect(!model.isWobbling)
        #expect(model.lastError != nil)
    }

    /// Nothing reports whether either is on, so what this model knows is only what
    /// it asked for — and it asked for nothing over a robot it never controlled.
    /// Reconnecting must not carry a stale claim across.
    @Test("a new model claims nothing about a robot it has not touched")
    func startsWithNoClaim() {
        let model = model(Calls())

        #expect(!model.isWobbling)
        #expect(!model.isTracking)
    }

    /// A joystick takes the head, and face tracking at `weight: 1` replaces the teleop
    /// pose outright rather than blending with it — so both behaviours let go before the
    /// pad starts driving.
    @Test("a deflection stands both behaviours down")
    func standsBothDown() async {
        let calls = Calls()
        let model = model(calls)
        let session = RobotSession.preview()
        await model.setWobbling(true, session: session)
        await model.setFaceTracking(true, session: session)

        await model.standDown(session: session)

        #expect(calls.wobbling == [true, false])
        #expect(calls.tracking == [true, false])
        #expect(!model.isWobbling)
        #expect(!model.isTracking)
    }

    /// The pad delivers its callback on every touch event, and neither flag turns false
    /// until its own call has been accepted — so without the latch a single drag would
    /// aim a POST per axis per frame at the robot for as long as the first pair is in
    /// flight. Twenty events land here before any of them can complete.
    @Test("a drag hands over once, not once per touch event")
    func handsOverOnlyOnce() async {
        let calls = Calls()
        let gate = Gate()
        let model = model(calls)
        let session = RobotSession.preview()
        await model.setWobbling(true, session: session)
        await model.setFaceTracking(true, session: session)
        calls.gate = gate

        let standDown = model.teleopStandDown(session: session)
        for _ in 0 ..< 20 {
            standDown()
        }
        gate.open()

        await waitUntil("the hand-off completes") { !model.isWobbling && !model.isTracking }
        #expect(calls.wobbling == [true, false])
        #expect(calls.tracking == [true, false])
    }

    /// Both are off already on every screen nobody has touched these switches on, and
    /// that is the common case: the pad must not talk to the robot for it.
    @Test("a deflection over a robot doing neither says nothing")
    func staysQuietWhenNeitherIsOn() async {
        let calls = Calls()
        let model = model(calls)

        model.teleopStandDown(session: .preview())()
        await model.standDown(session: .preview())

        #expect(calls.wobbling.isEmpty)
        #expect(calls.tracking.isEmpty)
    }

    /// A refused hand-off is not a hand-off. Recording it would leave the switch showing
    /// off over a robot still tracking, which is the one thing these controls must not
    /// do — so the next deflection asks again.
    @Test("a refused hand-off is retried on the next deflection")
    func retriesAfterFailure() async {
        let calls = Calls()
        let model = model(calls)
        let session = RobotSession.preview()
        await model.setWobbling(true, session: session)
        calls.failure = ReachyKitError.notConnected

        await model.standDown(session: session)
        #expect(model.isWobbling)

        calls.failure = nil
        await model.standDown(session: session)

        #expect(!model.isWobbling)
        #expect(calls.wobbling == [true, false])
    }

    // MARK: - How hard it follows

    /// The weight rides on *enabling*: `enable_head_tracking` takes it as a parameter and
    /// no route sets it alone, so a changed weight is a second enable.
    @Test("the weight the slider settled on is what the robot is told")
    func sendsTheWeightOnCommit() async {
        let calls = Calls()
        let model = model(calls)
        let session = RobotSession.preview()

        await model.setFaceTracking(true, session: session)
        #expect(calls.weights == [1])

        model.trackingWeight = 0.5
        await model.commitTrackingWeight(session: session)

        #expect(calls.tracking == [true, true])
        #expect(calls.weights == [1, 0.5])
    }

    /// A gesture that ends where it started is not a command. The route is idempotent, so
    /// this is thrift rather than a rule — but a slider that re-enables tracking on every
    /// touch is a slider nobody can rest a thumb on.
    @Test("committing an unchanged weight sends nothing")
    func skipsAnUnchangedWeight() async {
        let calls = Calls()
        let model = model(calls)
        let session = RobotSession.preview()

        await model.setFaceTracking(true, session: session)
        await model.commitTrackingWeight(session: session)

        #expect(calls.weights == [1])
    }

    /// While the switch is off the slider is a preference, not a control: the only route
    /// that carries the weight also turns tracking on, and doing that behind a switch
    /// somebody left off is not what dragging it asked for.
    @Test("the slider sends nothing while tracking is off")
    func staysSilentWhileOff() async {
        let calls = Calls()
        let model = model(calls)

        model.trackingWeight = 0.4
        await model.commitTrackingWeight(session: .preview())

        #expect(calls.tracking.isEmpty)
        #expect(!model.isTracking)
    }

    /// The preference outlives the switch, so turning tracking back on uses the number
    /// the reader chose rather than resetting to the whole of it.
    @Test("re-enabling tracking carries the weight last chosen")
    func remembersTheWeightAcrossTheSwitch() async {
        let calls = Calls()
        let model = model(calls)
        let session = RobotSession.preview()

        await model.setFaceTracking(true, session: session)
        model.trackingWeight = 0.3
        await model.commitTrackingWeight(session: session)
        await model.setFaceTracking(false, session: session)
        await model.setFaceTracking(true, session: session)

        #expect(calls.weights == [1, 0.3, 0.3, 0.3])
        #expect(model.isTracking)
    }

    /// A camera-less robot answers `enabled: false`, so nothing was applied — and the
    /// next commit must not read the refused number as already sent.
    @Test("a refused enable does not record its weight as applied")
    func doesNotRecordARefusedWeight() async {
        let calls = Calls()
        calls.trackingTakes = false
        let model = model(calls)
        let session = RobotSession.preview()

        model.trackingWeight = 0.5
        await model.setFaceTracking(true, session: session)
        #expect(!model.isTracking)

        // Off, so the commit is skipped for that reason rather than for the weight's.
        await model.commitTrackingWeight(session: session)
        #expect(calls.weights == [0.5])
    }

    @Test("the tracker is read only while it is running")
    func readsTheFaceOnlyWhileTracking() async throws {
        let calls = Calls()
        calls.face = RobotFaceTarget(x: 0.1, y: -0.2, roll: 0)
        let model = model(calls)
        let session = RobotSession.preview()
        #expect(model.seesFace == nil)
        #expect(calls.faceReadCount == 0)

        await model.setFaceTracking(true, session: session)
        await waitUntil("the robot reports a face") { model.seesFace == true }

        await model.setFaceTracking(false, session: session)
        // Unknown again rather than "nobody": the route reports the tracker's last
        // aim, and a stopped tracker has nothing current to say.
        #expect(model.seesFace == nil)
        // Captured after a pause rather than before one: a read already in flight
        // when the watch was cancelled still lands, and counting it against a total
        // taken earlier made a stopped poll look like a running one on a slow runner.
        // The pause is the assertion here — a non-event cannot be polled for.
        try await Task.sleep(for: .milliseconds(60))
        let settled = calls.faceReadCount
        try await Task.sleep(for: .milliseconds(60))
        #expect(calls.faceReadCount == settled)
    }

    @Test("an empty frame reads as nobody, a failed read as unknown")
    func separatesNobodyFromUnknown() async {
        let calls = Calls()
        let model = model(calls)
        let session = RobotSession.preview()

        await model.setFaceTracking(true, session: session)
        await waitUntil("the first read lands") { model.seesFace == false }

        calls.faceFailure = URLError(.timedOut)
        await waitUntil("the failure clears the reading") { model.seesFace == nil }
    }
}
