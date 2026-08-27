import ReachyKit
import ReachyMedia
import SwiftUI

/// The call framing's effects, beside `RootLifecycle` rather than inside it —
/// that body's own comment says it has no cyclomatic budget left. Everything
/// here is inert in previews and on macOS: the controller's facade no-ops off
/// iOS, and `previewMode` guards the rest.
///
/// What it does, in one place:
/// - keeps `RobotCallController` pointed at the connected robot;
/// - ends the call when the session under it goes away (robot asleep or
///   disconnected, stream failed, viewport target gone) — deliberately **not**
///   when the stream merely leaves `.streaming`, because `CameraSession`
///   self-heals through `.connecting` and the mic track comes back on its own;
/// - receives a Recents redial and routes call requests (Siri's included) —
///   Live tab, camera content, then unmute once the stream is up;
/// - donates the start-call intent each time a call actually starts.
struct RootCallLifecycle: ViewModifier {
    let session: RobotSession
    let viewport: ViewportModel
    let router: ReachyRouter
    let call: RobotCallController
    let remoteLink: RemoteRobotLink?

    /// `shared` for the reason `QuickActionInbox.shared` is: the intent that
    /// fills it runs with no initialiser to inject through.
    private let inbox = CallRequestInbox.shared

    @Environment(\.reachyPreviewMode) private var previewMode

    func body(content: Content) -> some View {
        content
            .onChange(of: connectedIdentity, initial: true) { _, identity in
                guard !previewMode else { return }
                call.robotChanged(id: identity?.deduplicationKey, name: identity?.name)
            }
            .onChange(of: callMustEnd) { _, mustEnd in
                guard !previewMode, mustEnd else { return }
                call.sessionBecameIneligible(failed: cameraHasFailed)
            }
            .onContinueUserActivity(CallActivity.activityType) { activity in
                guard !previewMode, let robotID = CallActivity.robotID(from: activity) else { return }
                inbox.receive(robotID: robotID)
            }
            .onChange(of: routingTrigger, initial: true) { _, _ in
                guard !previewMode else { return }
                routePendingRequest()
            }
            .onChange(of: call.donationCount) { _, _ in
                guard !previewMode, let active = call.activeCall else { return }
                CallActivity.donate(robotID: active.robotID, robotName: active.robotName)
            }
    }

    /// The identity through `.unreachable` too: a network blip must not read as
    /// a robot change and end the call — the same reading `publishHandoff`
    /// makes. Only the phases with no identity at all report none.
    private var connectedIdentity: RobotIdentity? {
        switch session.phase {
        case let .connected(identity), let .unreachable(identity): identity
        case .idle, .connecting: nil
        }
    }

    private var viewportTarget: ViewportModel.Source? {
        RootViewportTarget.source(session: session, remoteLink: remoteLink)
    }

    private var cameraHasFailed: Bool {
        if case .failed = viewport.cameraSession?.phase {
            return true
        }
        return false
    }

    private var callMustEnd: Bool {
        guard call.hasActiveCall else { return false }
        return viewportTarget == nil || !session.isAwake || cameraHasFailed
    }

    /// Everything a pending request waits on, in one `Equatable` value — the
    /// `EntityIndexTrigger` shape. A change to any of them re-runs the routing:
    /// the request arriving, the robot connecting, the stream coming up.
    private struct RoutingTrigger: Equatable {
        let pendingToken: Int?
        let robotID: String?
        let cameraIsStreaming: Bool
    }

    private var routingTrigger: RoutingTrigger {
        RoutingTrigger(
            pendingToken: inbox.pending?.token,
            robotID: connectedIdentity?.deduplicationKey,
            cameraIsStreaming: viewport.cameraSession?.phase == .streaming
        )
    }

    private func routePendingRequest() {
        guard let pending = inbox.pending else { return }
        guard !pending.request.isExpired(now: Date()) else {
            inbox.drop()
            return
        }
        switch CallRequestRouting.decide(
            requestRobotID: pending.request.robotID,
            connectedRobotID: connectedIdentity?.deduplicationKey,
            connectedRobotName: connectedIdentity?.name
        ) {
        case .waitForConnection:
            // Leave it pending; connecting re-fires the trigger and expiry
            // bounds the wait.
            break
        case .liveTabOnly:
            inbox.drop()
            router.tab = .live
        case .proceed:
            router.tab = .live
            guard session.hasCamera else {
                // A wired unit has no camera and therefore no call to place;
                // the Live tab saying so is the whole answer.
                inbox.drop()
                return
            }
            if viewport.content != .camera {
                viewport.setContent(.camera)
            }
            guard let camera = viewport.cameraSession, camera.phase == .streaming else {
                // Not up yet — the trigger fires again at `.streaming`.
                return
            }
            inbox.drop()
            call.startCall(for: camera)
        }
    }
}
