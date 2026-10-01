import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// A state socket a test feeds by hand.
private final class HandFedStream: RobotStateStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<StateStreamUpdate>.Continuation?
    private(set) var askedFor: StateStreamOptions?

    func updates(_ options: StateStreamOptions) -> AsyncStream<StateStreamUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: StateStreamUpdate.self)
        lock.lock()
        self.continuation = continuation
        askedFor = options
        lock.unlock()
        return stream
    }

    func send(_ frame: RobotStateFrame) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(StateStreamUpdate(frame: frame))
    }
}

/// The first run's pose on the LAN (#169): one frame off the daemon's socket per ask,
/// with the voice the robot heard joined onto it.
@MainActor
@Suite("First run state reader", .timeLimit(.minutes(1)))
struct FirstRunStateReaderTests {
    @Test("asks the socket for the motors and the voice, and nothing it does not read")
    func asksForWhatTheChecksRead() async throws {
        let stream = HandFedStream()
        let reader = FirstRunStateReader(stream: stream)

        let reading = Task { try await reader.next() }
        await waitUntil("the socket is open") { stream.askedFor != nil }
        stream.send(RobotStateFrame(headJoints: Array(repeating: 0, count: 7), antennas: [0, 0]))
        _ = try await reading.value

        let options = try #require(stream.askedFor)
        #expect(options.headJoints == true)
        #expect(options.antennaPositions == true)
        #expect(options.directionOfArrival == true)
        #expect(options.headPose == false)
    }

    @Test("a frame carries the motors and the voice together")
    func joinsTheVoiceOntoTheFrame() async throws {
        let stream = HandFedStream()
        let reader = FirstRunStateReader(stream: stream)
        let joints = [0, -0.17, 0.84, -0.12, 0.09, -0.81, 0.18]

        let reading = Task { try await reader.next() }
        await waitUntil("the socket is open") { stream.askedFor != nil }
        stream.send(RobotStateFrame(
            headJoints: joints,
            antennas: [-3.05, 3.05],
            directionOfArrival: .init(angle: 1.2, speechDetected: true)
        ))
        let frame = try #require(try await reading.value)

        #expect(frame.headJoints == joints)
        #expect(frame.antennas == [-3.05, 3.05])
        #expect(frame.directionOfArrival?.speechDetected == true)
    }

    /// Answering the same frame twice would let a socket that went quiet look alive
    /// for ever — the checks would go on concluding from a robot nobody is reading.
    @Test("a second ask waits for a newer frame, and a silent socket fails it")
    func waitsForANewerFrame() async throws {
        let stream = HandFedStream()
        let reader = FirstRunStateReader(stream: stream, frameTimeout: .milliseconds(200))

        let first = Task { try await reader.next() }
        await waitUntil("the socket is open") { stream.askedFor != nil }
        stream.send(RobotStateFrame(headJoints: Array(repeating: 0, count: 7), antennas: [0, 0]))
        _ = try await first.value

        await #expect(throws: (any Error).self) {
            try await reader.next()
        }
    }
}
