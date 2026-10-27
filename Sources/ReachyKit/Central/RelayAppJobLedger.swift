import Foundation
import ReachyJSON

/// Every app job's log as the relay reports it, kept from its first line.
///
/// Daemon 1.13.0 reports an install, removal or update over the data channel as
/// `apps.job_progress` notifications, `{job_id, command, status, line, final}`,
/// one per log line and a last one with `final: true` (`jsonrpc_relay.py`,
/// `_on_job_event`). Three facts about them decide this design:
///
/// - **They carry no line index and are never sent again.** A listener that
///   arrives late has missed those lines for good.
/// - **Nothing orders them against the reply that names the job.** The first lines
///   can arrive before the `job_id` they belong to.
/// - **They go to every client.** Another phone's install arrives here too.
///
/// So the ledger listens before the first job verb is sent and records every job
/// from line 0, and ``log(of:)`` replays what it holds before it goes live. The
/// replay index is then the index of `apps.job_status`'s `logs`, which is what lets
/// `AppJobMonitor`'s single cursor keep the poll and this stream from doubling a
/// line. A job it joined late — an `apps.update` answered `started: false` — has no
/// such index, so its stream carries the end alone and its lines come from the poll.
actor RelayAppJobLedger {
    static let method = "apps.job_progress"
    /// Jobs kept, oldest dropped first. Other clients' jobs are recorded too, and a
    /// robot left installing for a day must not grow this without end.
    static let capacity = 16

    private struct Record {
        var lines: [String] = []
        var end: DaemonJob.Status?
        /// Joined after it began: its lines here do not start at line 0.
        var isPartial = false
    }

    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var followers: [String: [UUID: AsyncStream<JobLogEvent>.Continuation]] = [:]
    private var listening: Task<Void, Never>?

    /// Subscribes once, before the first job verb goes out. Every frame after this
    /// returns is buffered for the ledger, so none can be lost to the race above.
    func listen(to control: RemoteControlChannel) async {
        guard listening == nil else { return }
        let frames = await control.broadcasts(ofType: Self.method, buffering: .unbounded)
        listening = Task { [weak self] in
            for await frame in frames {
                await self?.record(frame)
            }
            await self?.endAll()
        }
    }

    /// The job's log so far, then live, then its end. Ends at once for a job that
    /// is already over.
    func log(of jobID: String) -> AsyncStream<JobLogEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: JobLogEvent.self)
        let record = records[jobID] ?? Record()
        if !record.isPartial {
            for line in record.lines {
                continuation.yield(.line(line))
            }
        }
        if let end = record.end {
            continuation.yield(.status(end))
            continuation.yield(.closed)
            continuation.finish()
            return stream
        }
        let id = UUID()
        followers[jobID, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropFollower(id, of: jobID) }
        }
        return stream
    }

    /// An `apps.update` that joined a job already running. Its lines before now
    /// were never seen here, so none of its lines are passed on as indexed ones.
    func markJoined(_ jobID: String) {
        var record = records[jobID] ?? Record()
        record.isPartial = true
        store(record, for: jobID)
    }

    func record(_ frame: Data) {
        guard let progress = try? JSONCodec.daemon.decode(Notification.self, from: frame).params else { return }
        var record = records[progress.jobID] ?? Record()
        if let line = progress.line {
            record.lines.append(line)
            if !record.isPartial {
                yield(.line(line), to: progress.jobID)
            }
        }
        if progress.final {
            record.end = progress.status
            yield(.status(progress.status), to: progress.jobID)
            yield(.closed, to: progress.jobID)
            for continuation in followers.removeValue(forKey: progress.jobID)?.values ?? [:].values {
                continuation.finish()
            }
        }
        store(record, for: progress.jobID)
    }

    private func store(_ record: Record, for jobID: String) {
        if records[jobID] == nil {
            order.append(jobID)
        }
        records[jobID] = record
        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            records[oldest] = nil
        }
    }

    private func yield(_ event: JobLogEvent, to jobID: String) {
        for continuation in followers[jobID]?.values ?? [:].values {
            continuation.yield(event)
        }
    }

    /// The channel ended, so no job reports again. `.closed` is not an outcome:
    /// the poll still asks how each one ended.
    private func endAll() {
        for continuation in followers.values.flatMap(\.values) {
            continuation.yield(.closed)
            continuation.finish()
        }
        followers = [:]
        listening = nil
    }

    private func dropFollower(_ id: UUID, of jobID: String) {
        followers[jobID]?.removeValue(forKey: id)
        if followers[jobID]?.isEmpty == true {
            followers[jobID] = nil
        }
    }

    private struct Notification: Decodable {
        let params: Progress
    }

    private struct Progress: Decodable {
        let jobID: String
        let status: DaemonJob.Status
        let line: String?
        let final: Bool

        private enum CodingKeys: String, CodingKey {
            case status, line, final
            case jobID = "job_id"
        }
    }
}

/// A transport whose app jobs report their log through ``RelayAppJobLedger``.
public protocol RelayAppJobClient: Sendable {
    func jobLog(id jobID: String) async -> AsyncStream<JobLogEvent>
}
