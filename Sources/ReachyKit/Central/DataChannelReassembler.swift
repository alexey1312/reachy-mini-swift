import Foundation
import ReachyJSON

/// Joins the `message_chunk` frames a daemon splits a large message into.
///
/// The data channel drops any message over 64 KiB, and nothing on the sending
/// side sees it go: the daemon's GStreamer reports it only as an internal warning,
/// and the call it answered sits out its whole deadline here. Upstream therefore
/// splits anything over 60 000 bytes into ordered frames
/// (`split_for_data_channel`, pollen-robotics/reachy_mini#1438) —
/// `{"type": "message_chunk", "id", "index", "count", "data"}`, where `data` is a
/// slice of the original text and the slices joined in order *are* the message.
/// A message that fits is sent unchanged, so on a daemon without the split this
/// type never sees a frame.
///
/// The channel is ordered, so there is nothing to reorder: a gap means the
/// message is gone, and its parts are dropped rather than held for a frame that
/// will not come. One per channel, and emptied with it — a new channel is a new
/// session, and a message cannot straddle two.
struct DataChannelReassembler {
    /// Upstream's own ceiling (`MAX_CHUNKS` in the SDK's `message-chunks.ts`):
    /// 4096 frames of 4096 characters, against a sender that never stops.
    static let maximumChunks = 4096

    /// The frame type the daemon splits under. Routed here by ``Envelope``'s
    /// `.typed` case, which is what keeps whole frames from being decoded twice.
    static let frameType = "message_chunk"

    private var partials: [String: [String]] = [:]

    /// Parts held for messages still arriving. Exposed for tests, which have no
    /// other way to tell a dropped message from one still being assembled.
    var pendingMessages: Int {
        partials.count
    }

    /// Feeds one `message_chunk` frame. Answers the whole message once this frame
    /// completes it, and nil while it is still arriving or after it was lost.
    mutating func accept(_ frame: Data) -> String? {
        guard let chunk = try? JSONCodec.daemon.decode(Chunk.self, from: frame),
              (1 ... Self.maximumChunks).contains(chunk.count),
              (0 ..< chunk.count).contains(chunk.index)
        else {
            return nil
        }
        var parts = chunk.index == 0 ? [] : partials[chunk.id]
        guard parts?.count == chunk.index else {
            partials[chunk.id] = nil
            return nil
        }
        parts?.append(chunk.data)
        guard let parts, parts.count == chunk.count else {
            partials[chunk.id] = parts
            return nil
        }
        partials[chunk.id] = nil
        return parts.joined()
    }

    mutating func reset() {
        partials = [:]
    }

    private struct Chunk: Decodable {
        let id: String
        let index: Int
        let count: Int
        let data: String
    }
}
