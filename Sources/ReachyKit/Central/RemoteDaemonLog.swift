import Foundation
import ReachyJSON

/// The daemon's journal over the data channel.
///
/// `subscribe_logs` is answered with silence — `_start_log_subscription` replies
/// only when the transport has no peer id, and otherwise just starts the
/// journal task — so it is *sent* rather than performed. The first `log_line` is
/// the only confirmation there is.
///
/// Unlike the LAN route this does not need `--wireless-version`: the WebSocket at
/// `/logs/ws/daemon` is mounted only under that flag, while this rides the
/// channel every robot's media server already opens.
struct RemoteDaemonLog: Sendable {
    /// `journalctl --output short-iso` splits at the first space, and the daemon
    /// sends the two halves separately so a consumer can render them apart. This
    /// one puts them back together, because `LogEntry` parses exactly the shape
    /// the WebSocket route delivers.
    static let lineType = "log_line"
    static let errorType = "log_stream_error"

    let control: RemoteControlChannel

    func lines() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(500)
        )
        let pump = Task {
            let lines = await control.broadcasts(ofType: Self.lineType)
            let errors = await control.broadcasts(ofType: Self.errorType)
            // Subscribed before the command goes out: the robot starts streaming
            // the last 100 lines the moment it is asked, and a subscription set up
            // afterwards would miss them.
            try? await control.send("subscribe_logs")

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await data in lines {
                        guard let line = try? JSONCodec.daemon.decode(LineMessage.self, from: data) else { continue }
                        continuation.yield(line.text)
                    }
                }
                group.addTask {
                    for await data in errors {
                        guard let failure = try? JSONCodec.daemon.decode(ErrorMessage.self, from: data) else {
                            continue
                        }
                        // Rendered as a journal line rather than swallowed: the
                        // subscription is over after this, and "journalctl not
                        // found" is the answer to why the console stopped.
                        continuation.yield("ERROR log stream: \(failure.error)")
                        break
                    }
                }
                await group.next()
                group.cancelAll()
            }
            continuation.finish()
        }
        continuation.onTermination = { [control] _ in
            pump.cancel()
            Task { try? await control.send("unsubscribe_logs") }
        }
        return stream
    }

    private struct LineMessage: Decodable {
        let timestamp: String
        let line: String

        /// Rejoined with the single space `short-iso` puts between them, so what
        /// arrives here is byte-identical to what the WebSocket route yields and
        /// `LogEntry` needs no second parser.
        var text: String {
            timestamp.isEmpty ? line : "\(timestamp) \(line)"
        }
    }

    private struct ErrorMessage: Decodable {
        let error: String
    }
}
