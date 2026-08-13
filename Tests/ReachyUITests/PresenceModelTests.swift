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
        /// What the robot answers `setFaceTracking` with — false is a camera-less one.
        var trackingTakes = true
        var failure: (any Error)?

        func wobble(_ value: Bool) throws {
            if let failure {
                throw failure
            }
            lock.withLock { wobbling.append(value) }
        }

        func track(_ value: Bool) throws -> Bool {
            if let failure {
                throw failure
            }
            lock.withLock { tracking.append(value) }
            return value && trackingTakes
        }
    }

    private func model(_ calls: Calls) -> PresenceModel {
        PresenceModel(
            setWobbling: { _, value in try calls.wobble(value) },
            setFaceTracking: { _, value in try calls.track(value) }
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
}
