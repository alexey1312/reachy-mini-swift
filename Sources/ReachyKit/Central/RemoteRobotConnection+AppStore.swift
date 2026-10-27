import Foundation
import ReachyJSON

/// The robot's own store over the relay, from daemon 1.13.0
/// (pollen-robotics/reachy_mini#1471, #1477): what is installed, installs by
/// Space id, removals and updates as jobs, and each job's progress.
///
/// `RobotSession.hasRelayAppStore` decides whether any of this is asked: an older
/// robot answers every verb here with `-32601`, and the transport cannot read the
/// version itself. The reply shapes are `jsonrpc_relay.py`'s at v1.13.0, and were
/// read off the daemon's own `JsonRpcRelay` driving a real `AppManager`.
extension RemoteRobotConnection: RelayAppJobClient {
    public nonisolated var carriesRelayAppStore: Bool {
        true
    }

    /// `apps.list_installed`: `{apps: [{name, description, url, space_id, title,
    /// emoji, private, custom_app_url}]}` — the daemon's own cut, without the raw
    /// Space metadata the LAN list carries.
    public func installedApps() async throws -> [RobotApp] {
        try await control.call("apps.list_installed", expecting: InstalledReply.self).apps.map(\.app)
    }

    /// `apps.install_space {space_id}`, a job. By Space id rather than by the slug
    /// `apps.install` matches, so a fork can never stand in for the app on the card.
    public func installApp(_ app: RobotApp) async throws -> String {
        guard let spaceID = app.spaceID else { throw ReachyKitError.appsUnavailable }
        return try await installPrivateSpace(id: spaceID)
    }

    /// The same verb: the robot fetches a private Space with the token it stores.
    public func installPrivateSpace(id spaceID: String) async throws -> String {
        await jobs.listen(to: control)
        return try await control.call(
            "apps.install_space",
            params: ["space_id": .string(spaceID)],
            expecting: JobReply.self
        ).jobID
    }

    /// `apps.remove {name}`, a job. Refused with `startup_app` for the app the robot
    /// starts on wake-up: unsetting that is HTTP.
    public func removeApp(named name: String) async throws -> String {
        await jobs.listen(to: control)
        return try await control.call("apps.remove", params: ["name": .string(name)], expecting: JobReply.self).jobID
    }

    /// `apps.update {name}`, a job. The daemon stops the app first when it is the
    /// one running, waiting up to 25 s for it, so this waits on the stop's budget.
    /// `started: false` names a job for this app that was already running.
    public func updateApp(named name: String) async throws -> String {
        await jobs.listen(to: control)
        let reply = try await control.call(
            "apps.update",
            params: ["name": .string(name)],
            timeout: Self.appStopTimeout,
            expecting: UpdateReply.self
        )
        if !reply.started {
            await jobs.markJoined(reply.jobID)
        }
        return reply.jobID
    }

    /// `apps.job_status {job_id}`: `{job_id, command, status, logs}`.
    ///
    /// The job register lives in the daemon's memory, so a daemon that restarted
    /// answers `unknown_job` for work that really did start. That is the LAN's 404,
    /// and it is passed on as one, so `AppJobMonitor` ends on `.daemonRestarted`
    /// over either link.
    public func appJob(id jobID: String) async throws -> DaemonJob {
        do {
            return try await control.call(
                "apps.job_status",
                params: ["job_id": .string(jobID)],
                expecting: DaemonJob.self
            )
        } catch let RemoteControlChannel.Failure.rpc(_, message, reason) where reason == "unknown_job" {
            throw ReachyKitError.daemonRefused(statusCode: 404, detail: message)
        }
    }

    /// `apps.check_update {name}`. One Hugging Face call on the robot.
    public func appUpdateCheck(named name: String) async throws -> AppUpdateCheck {
        try await control.call("apps.check_update", params: ["name": .string(name)], expecting: AppUpdateCheck.self)
    }

    public func jobLog(id jobID: String) async -> AsyncStream<JobLogEvent> {
        await jobs.log(of: jobID)
    }

    private struct InstalledReply: Decodable {
        let apps: [Installed]
    }

    /// One row of `apps.list_installed`, rebuilt into the `AppInfo` the LAN list
    /// carries, so the store joins it to a catalogue card the same way:
    /// `extra.id` is the Space id `RobotApp.matches(installed:)` compares first.
    private struct Installed: Decodable {
        let name: String
        let description: String?
        let url: String?
        let spaceID: String?
        let title: String?
        let emoji: String?
        let isPrivate: Bool?
        let customAppURL: String?

        private enum CodingKeys: String, CodingKey {
            case name, description, url, title, emoji
            case spaceID = "space_id"
            case isPrivate = "private"
            case customAppURL = "custom_app_url"
        }

        var app: RobotApp {
            var card: [String: RemoteValue] = [:]
            if let title {
                card["title"] = .string(title)
            }
            if let emoji {
                card["emoji"] = .string(emoji)
            }
            var extra: [String: RemoteValue] = ["cardData": .object(card)]
            if let spaceID {
                extra["id"] = .string(spaceID)
                // The relay sends no author, and the Space id starts with it — which
                // is what `isOfficial` reads.
                if let owner = spaceID.split(separator: "/").first {
                    extra["author"] = .string(String(owner))
                }
            }
            if let isPrivate {
                extra["private"] = .bool(isPrivate)
            }
            if let customAppURL {
                extra["custom_app_url"] = .string(customAppURL)
            }
            var info: [String: RemoteValue] = [
                "name": .string(name),
                "source_kind": .string("installed"),
                "extra": .object(extra),
            ]
            if let description {
                info["description"] = .string(description)
            }
            if let url {
                info["url"] = .string(url)
            }
            // Through the daemon's own decoder, so the row is exactly what the LAN's
            // `list-available/installed` would have produced for the same fields.
            guard let data = try? JSONCodec.daemon.encode(info),
                  let app = try? JSONCodec.daemon.decode(RobotApp.self, from: data)
            else {
                let info = Components.Schemas.AppInfo(name: name, sourceKind: .installed, description: description)
                return RobotApp(info)
            }
            return app
        }
    }

    private struct JobReply: Decodable {
        let jobID: String

        private enum CodingKeys: String, CodingKey {
            case jobID = "job_id"
        }
    }

    private struct UpdateReply: Decodable {
        let started: Bool
        let jobID: String

        private enum CodingKeys: String, CodingKey {
            case started
            case jobID = "job_id"
        }
    }
}
