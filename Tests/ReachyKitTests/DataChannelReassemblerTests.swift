import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

/// The `message_chunk` framing pollen-robotics/reachy_mini#1438 puts on the data
/// channel for anything over 60 000 bytes. The frames here are built the way the
/// daemon's `split_for_data_channel` builds them — slices of the original text,
/// in order, under one id — so a join that is wrong about any of that fails.
@Suite("Data channel — chunked messages", .timeLimit(.minutes(1)))
struct DataChannelReassemblerTests {
    @Test("the slices of one message join back into it")
    func joinsInOrder() throws {
        var reassembler = DataChannelReassembler()
        let message = #"{"jsonrpc":"2.0","id":7,"result":{"avatar":"ÿ😀 and more"}}"#
        let frames = try Self.split(message, size: 9, id: "a")

        let delivered = frames.map { reassembler.accept($0) }

        #expect(delivered.dropLast().allSatisfy { $0 == nil })
        #expect(delivered.last == message)
        #expect(reassembler.pendingMessages == 0)
    }

    /// The channel is ordered, so a gap is a loss and not a late arrival. Holding
    /// the parts would join the next message's tail onto this one's head.
    @Test("a missing slice drops the whole message")
    func dropsAMessageWithAGap() throws {
        var reassembler = DataChannelReassembler()
        var frames = try Self.split(String(repeating: "x", count: 30), size: 10, id: "a")
        frames.remove(at: 1)

        let delivered = frames.compactMap { reassembler.accept($0) }

        #expect(delivered.isEmpty)
        #expect(reassembler.pendingMessages == 0)
    }

    @Test("two messages in flight at once are kept apart by id")
    func keepsInterleavedMessagesApart() throws {
        var reassembler = DataChannelReassembler()
        let first = try Self.split("first message", size: 5, id: "a")
        let second = try Self.split("second one", size: 4, id: "b")
        let interleaved = zip(first, second).flatMap { [$0, $1] } + first.dropFirst(second.count)

        let delivered = interleaved.compactMap { reassembler.accept($0) }

        #expect(Set(delivered) == ["first message", "second one"])
    }

    /// Upstream's own ceiling. A sender that announces more is refused outright,
    /// and nothing is held for it.
    @Test("a count beyond the ceiling, or an index beyond the count, is refused")
    func refusesImpossibleFrames() throws {
        var reassembler = DataChannelReassembler()
        let tooMany = try Self.frame(id: "a", index: 0, count: DataChannelReassembler.maximumChunks + 1, data: "x")
        let pastTheEnd = try Self.frame(id: "b", index: 3, count: 3, data: "x")

        #expect(reassembler.accept(tooMany) == nil)
        #expect(reassembler.accept(pastTheEnd) == nil)
        #expect(reassembler.pendingMessages == 0)
    }

    /// The point of the whole type: `personalities.avatar` answers with far more
    /// than one frame can carry, and the call used to sit out its deadline.
    @Test("a JSON-RPC reply that arrives in slices answers its call")
    func answersACallInSlices() async throws {
        let fake = FakeDataChannel(isOpen: true)
        let control = RemoteControlChannel(channel: fake, timeout: .seconds(5), openingTimeout: .seconds(5))

        async let reply: Data = control.call("personalities.avatar")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        let payload = #"{"jsonrpc":"2.0","id":1,"result":{"png":""# + String(repeating: "A", count: 200) + #""}}"#
        for frame in try Self.split(payload, size: 64, id: "r") {
            try fake.emit(#require(String(bytes: frame, encoding: .utf8)))
        }

        #expect(try await reply == Data(payload.utf8))
    }

    @Test("a broadcast that arrives in slices reaches its subscribers whole")
    func deliversABroadcastInSlices() async throws {
        let fake = FakeDataChannel(isOpen: true)
        let control = RemoteControlChannel(channel: fake, timeout: .seconds(5), openingTimeout: .seconds(5))
        let logs = await control.broadcasts(ofType: "daemon_log")
        let line = #"{"type":"daemon_log","line":""# + String(repeating: "L", count: 100) + #""}"#

        await waitUntil("the reader is listening") { fake.isListening }
        for frame in try Self.split(line, size: 30, id: "l") {
            try fake.emit(#require(String(bytes: frame, encoding: .utf8)))
        }

        var iterator = logs.makeAsyncIterator()
        #expect(await iterator.next() == Data(line.utf8))
    }

    // MARK: - Frames as the daemon builds them

    private static func split(_ message: String, size: Int, id: String) throws -> [Data] {
        let characters = Array(message)
        let count = (characters.count + size - 1) / size
        return try (0 ..< count).map { index in
            let slice = characters[(index * size) ..< min((index + 1) * size, characters.count)]
            return try frame(id: id, index: index, count: count, data: String(slice))
        }
    }

    private static func frame(id: String, index: Int, count: Int, data: String) throws -> Data {
        struct Frame: Encodable {
            let type = DataChannelReassembler.frameType
            let id: String
            let index: Int
            let count: Int
            let data: String
        }
        return try JSONCodec.daemon.encode(Frame(id: id, index: index, count: count, data: data))
    }
}

private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
