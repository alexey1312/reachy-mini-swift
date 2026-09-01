import Foundation
@testable import ReachyKit
import Testing

/// The pose channel is unordered and lossy by design, so what this pins is which
/// frames reach the viewer and which are dropped on the floor.
@Suite("Remote pose stream", .timeLimit(.minutes(1)))
struct RemotePoseStreamTests {
    private func frame(seq: Int, yaw: Double) -> String {
        #"{"seq":\#(seq),"state":{"body_yaw":\#(yaw),"antennas":[0,0]}}"#
    }

    private func stream() -> (RemotePoseStream, FakeDataChannel) {
        let control = FakeDataChannel()
        let pose = FakeDataChannel()
        return (
            RemotePoseStream(
                connection: RemoteRobotConnection(channel: control, timeout: .seconds(5)),
                channel: pose
            ),
            pose
        )
    }

    @Test("a newer frame reaches the viewer")
    func deliversFrames() async throws {
        let (stream, pose) = stream()
        var frames = stream.updates(.visualization).makeAsyncIterator()

        pose.emit(frame(seq: 1, yaw: 0.25))

        let update = try #require(await frames.next())
        #expect(update.frame?.bodyYaw == 0.25)
    }

    /// The channel may deliver out of order, and an older frame is stale rather
    /// than new — drawing it would jerk the model backwards.
    @Test("a frame that arrives late is dropped, not drawn")
    func dropsStaleFrames() async throws {
        let (stream, pose) = stream()
        var frames = stream.updates(.visualization).makeAsyncIterator()

        pose.emit(frame(seq: 1, yaw: 0.1))
        pose.emit(frame(seq: 3, yaw: 0.3))
        pose.emit(frame(seq: 2, yaw: 0.2))
        pose.emit(frame(seq: 4, yaw: 0.4))

        var seen: [Double] = []
        for _ in 0 ..< 3 {
            let update = try #require(await frames.next())
            if let yaw = update.frame?.bodyYaw {
                seen.append(yaw)
            }
        }
        #expect(seen == [0.1, 0.3, 0.4])
    }

    /// A frame this build cannot read must not stop the stream: the next one is a
    /// thirtieth of a second away.
    @Test("an unreadable frame is counted and stepped over")
    func survivesGarbage() async throws {
        let (stream, pose) = stream()
        var frames = stream.updates(.visualization).makeAsyncIterator()

        pose.emit("not json at all")
        pose.emit(frame(seq: 1, yaw: 0.5))

        let update = try #require(await frames.next())
        #expect(update.frame?.bodyYaw == 0.5)
        #expect(update.diagnostics.decodeFailures == 1)
    }

    /// The channel hands its stream to one reader and finishes the previous one, so
    /// the 3D scene and the hearing indicator cannot each open their own. This is
    /// what lets them share.
    @Test("every subscriber sees the same frame")
    func fansOutToEverySubscriber() async {
        let (stream, pose) = stream()
        var scene = stream.updates(.visualization).makeAsyncIterator()
        var hearing = stream.updates(.hearing).makeAsyncIterator()

        pose.emit(frame(seq: 1, yaw: 0.75))

        #expect(await scene.next()?.frame?.bodyYaw == 0.75)
        #expect(await hearing.next()?.frame?.bodyYaw == 0.75)
    }

    /// The direction is the one field the relay never carried, and it rides the
    /// same frame as the pose.
    @Test("a snapshot carrying only a direction still reaches the indicator")
    func deliversTheDirection() async throws {
        let (stream, pose) = stream()
        var frames = stream.updates(.hearing).makeAsyncIterator()

        pose.emit(#"{"seq":1,"state":{"doa":{"angle":2.9,"speech_detected":true}}}"#)

        let update = try #require(await frames.next())
        #expect(update.hearing?.speechDetected == true)
        #expect(update.hearing?.angle == 2.9)
    }
}
