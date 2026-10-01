import Foundation
import Observation
import ReachyKit

// The #159 prototype, which ships to nobody (ADR 0006).
#if DEBUG
    /// One hosted JS app, from the page loading to the page having let go of the
    /// robot (ADR 0006).
    ///
    /// The page owns the robot while it runs — it opens a session of its own through
    /// central — so everything here is narration of what the page reports, plus the
    /// one thing the host must do itself: ask the page to leave, and wait for it to
    /// put the robot to sleep, before tearing it down.
    @MainActor
    @Observable
    final class JSAppHostModel: Identifiable {
        enum Phase: Equatable {
            /// The page is loading and has said nothing yet.
            case loading
            /// Reaching the robot: central, the session, the wake-up animation.
            case connecting(JSAppHostProtocol.AppState.Step?)
            case live
            /// Asked to leave and putting the robot to sleep.
            case leaving
            /// Done — the page may be torn down.
            case left
            /// The page or the app failed; the reason is runtime text.
            case failed(String)
        }

        /// The reference host waits this long for `embed:left` before unmounting
        /// anyway (`useHostBridge.ts`), and the page's own leave is bounded below it:
        /// a 6.5 s sleep plus a second to confirm the motors are off.
        static let leaveTimeout: Duration = .milliseconds(9500)

        let id = UUID()
        let app: JSApp
        let url: URL
        private(set) var phase: Phase = .loading
        private(set) var daemonVersion: String?
        /// The page asked to be closed. The screen owns closing, so it watches this.
        private(set) var closeRequested = false
        /// What the page has said, newest last, for the prototype's diagnostics.
        private(set) var transcript: [String] = []

        /// Runs a script in the page. Set by the web view once it exists.
        @ObservationIgnored var evaluate: ((String) -> Void)?

        private let leaveTimeout: Duration
        /// Everyone waiting for the page to let go — a second Close joins the first.
        @ObservationIgnored private var leaveWaiters: [CheckedContinuation<Void, Never>] = []
        @ObservationIgnored private var leaveDeadline: Task<Void, Never>?

        init(app: JSApp, url: URL, leaveTimeout: Duration = JSAppHostModel.leaveTimeout) {
            self.app = app
            self.url = url
            self.leaveTimeout = leaveTimeout
        }

        func receive(_ message: JSAppHostProtocol.PageMessage) {
            record(message)
            switch message {
            case .ready, .other:
                break
            case let .appState(state):
                if let version = state.daemonVersion {
                    daemonVersion = version
                }
                apply(state)
            case .requestLeave:
                closeRequested = true
            case .left:
                finishLeaving()
            case let .error(message, fatal):
                guard fatal, phase != .leaving, phase != .left else { return }
                phase = .failed(message)
            }
        }

        /// The page itself did not load — a navigation failure or a web content
        /// process that died. Not the app's own error, which arrives as a message.
        func pageFailed(_ message: String) {
            guard phase != .left else { return }
            phase = .failed(message)
            // Nothing is left to answer a leave that is waiting.
            if !leaveWaiters.isEmpty {
                finishLeaving()
            }
        }

        /// Asks the page to leave and waits until it has, or until `leaveTimeout`.
        ///
        /// **The wait is for the robot, not for the page.** The page answers
        /// `host:leaving` by putting the robot to sleep and stopping its session, and
        /// tearing the web view down first would leave the session to time out on
        /// central's side and the head wherever the app left it. A page that never got
        /// as far as a session has nothing to put down and is let go at once.
        func leave() async {
            switch phase {
            case .left:
                return
            case .loading, .failed:
                phase = .left
                return
            case .leaving:
                break
            case .connecting, .live:
                phase = .leaving
                if let script = try? JSAppHostProtocol.leaving(reason: .userAction, timeout: leaveTimeout) {
                    evaluate?(JSAppHostBridge.post(script))
                }
            }
            if leaveDeadline == nil {
                let timeout = leaveTimeout
                leaveDeadline = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishLeaving()
                }
            }
            await withCheckedContinuation { leaveWaiters.append($0) }
        }

        private func apply(_ state: JSAppHostProtocol.AppState) {
            // Once leaving, only `embed:left` moves the phase on — a late `live` from a
            // reconnect must not reopen an app the reader has closed.
            guard phase != .leaving, phase != .left else { return }
            switch state.phase {
            case .boot:
                phase = .loading
            case .connecting:
                phase = .connecting(state.step)
            case .live:
                phase = .live
            case .leaving:
                phase = .leaving
            case .error:
                phase = .failed(state.message ?? "")
            }
        }

        private func finishLeaving() {
            phase = .left
            leaveDeadline?.cancel()
            leaveDeadline = nil
            let waiters = leaveWaiters
            leaveWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }

        private func record(_ message: JSAppHostProtocol.PageMessage) {
            let line = switch message {
            case .ready: "embed:ready"
            case let .appState(state): "embed:app-state \(state.phase.rawValue) \(state.step?.rawValue ?? "")"
            case .requestLeave: "embed:request-leave"
            case .left: "embed:left"
            case let .error(message, fatal): "embed:error \(fatal ? "fatal" : "non-fatal"): \(message)"
            case let .other(type): type
            }
            transcript.append(line)
            if transcript.count > 50 {
                transcript.removeFirst(transcript.count - 50)
            }
        }
    }
#endif
