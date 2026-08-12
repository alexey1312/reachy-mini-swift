import Foundation
import ReachyJSON

/// One message from a daemon job socket.
public enum JobLogEvent: Sendable, Equatable {
    case line(String)
    case status(DaemonJob.Status)
    /// The daemon does not know this job — always the first and only frame.
    case rejected(String)
    /// The socket ended. For a daemon update this, not a `done` status, is what
    /// completion looks like: the update finishes by restarting the daemon, which
    /// kills the process before the terminal frame is ever written. An app job
    /// leaves the daemon standing and does send its terminal status first.
    case closed
}

/// The name the update screens have always used.
public typealias UpdateLogEvent = JobLogEvent

/// Streams one background job's log.
///
/// Both daemon sockets that carry job logs are served by the same
/// `bg_job_register.ws_poll_info`, so they are one client with two addresses:
///
/// - `ws://…/update/ws/logs?job_id=…` for the daemon's own software update;
/// - `ws://…/api/apps/ws/apps-manager/{job_id}` for an app install, removal or
///   update.
///
/// Two deliberate properties, both inherited from that shared implementation:
///
/// - **No reconnect.** The job register lives in memory. A daemon that restarts —
///   which is how an update ends — takes every job with it, so reconnecting would
///   hammer a rebooting daemon and never find the job again afterwards.
/// - **Two frame shapes on one socket.** Each new line arrives as its own text
///   frame and *then* inside a `JobInfo` JSON frame repeating those same lines.
///   Decoding both would duplicate every line, so a frame that parses as JSON
///   contributes only its status.
///
/// The socket also only ever wakes on a *new log line*: a job that finished before
/// the socket was opened never sends anything at all. Anything driving this stream
/// has to poll `job-status` alongside it — see `AppJobMonitor`.
public struct JobLogStreamClient: Sendable {
    public static let updatePath = "/update/ws/logs"
    public static let appsManagerPath = "/api/apps/ws/apps-manager"

    let url: URL
    private let session: URLSession

    /// The daemon's own software update. The job id is a query parameter here.
    public static func daemonUpdate(
        address: RobotAddress,
        jobID: String,
        session: URLSession = .shared
    ) throws -> Self {
        guard let url = address.webSocketURL(
            path: updatePath,
            queryItems: [URLQueryItem(name: "job_id", value: jobID)]
        ) else {
            throw ReachyKitError.invalidAddress(address)
        }
        return Self(url: url, session: session)
    }

    /// An app install, removal or update. The job id is a path segment here.
    public static func appsManager(
        address: RobotAddress,
        jobID: String,
        session: URLSession = .shared
    ) throws -> Self {
        guard let url = address.webSocketURL(path: "\(appsManagerPath)/\(jobID)") else {
            throw ReachyKitError.invalidAddress(address)
        }
        return Self(url: url, session: session)
    }

    /// Ends with exactly one `.closed`, whether the daemon finished, restarted or died.
    public func events() -> AsyncStream<JobLogEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: JobLogEvent.self,
            bufferingPolicy: .bufferingNewest(1000)
        )
        let task = Task { [url, session] in
            let socket = session.webSocketTask(with: url)
            socket.resume()
            defer {
                socket.cancel(with: .goingAway, reason: nil)
                continuation.yield(.closed)
                continuation.finish()
            }
            // `receive()` does not observe task cancellation (see
            // `ConversationRPCClient.read`), and this socket only ever wakes
            // on a new log line — a consumer that leaves mid-job would park
            // here forever, and the `defer` above would never run. The
            // handler makes `receive()` throw so the task can actually end.
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    guard let message = try? await socket.receive() else { return }
                    guard case let .string(text) = message else { continue }
                    for event in Self.events(in: text) {
                        continuation.yield(event)
                        if case .rejected = event {
                            return
                        }
                    }
                }
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// A frame is either a raw log line or one of the two JSON shapes the daemon sends.
    static func events(in frame: String) -> [JobLogEvent] {
        struct Rejection: Decodable {
            let error: String
        }
        guard let data = frame.data(using: .utf8) else {
            return [.line(frame)]
        }
        if let rejection = try? JSONCodec.daemon.decode(Rejection.self, from: data) {
            return [.rejected(rejection.error)]
        }
        if let job = try? JSONCodec.daemon.decode(DaemonJob.self, from: data) {
            // `job.logs` repeats lines already delivered as their own frames.
            return [.status(job.status)]
        }
        return [.line(frame)]
    }
}
