#if DEBUG
    import Foundation
    import ReachyKit
    @testable import ReachyUI
    import Testing

    /// A hosted JS app's lifecycle as the page reports it, and the one thing the
    /// host does itself: ask the page to leave and wait for it to let the robot go.
    @MainActor
    @Suite("JS app host", .timeLimit(.minutes(1)))
    struct JSAppHostModelTests {
        private static let app = JSApp(id: "tfrere/reachy-mini-sdkjs-demo-static", title: "Hello")

        private func model(leaveTimeout: Duration = .seconds(10)) -> (JSAppHostModel, Sent) {
            let model = JSAppHostModel(
                app: Self.app,
                url: URL(string: "https://tfrere-reachy-mini-sdkjs-demo-static.static.hf.space/")!,
                leaveTimeout: leaveTimeout
            )
            let sent = Sent()
            model.evaluate = { sent.scripts.append($0) }
            return (model, sent)
        }

        @MainActor
        private final class Sent {
            var scripts: [String] = []
        }

        private func live(_ model: JSAppHostModel) {
            model.receive(.ready)
            model.receive(.appState(.init(phase: .connecting, step: .link)))
            model.receive(.appState(.init(phase: .connecting, step: .wake)))
            model.receive(.appState(.init(phase: .live, daemonVersion: "1.11.0")))
        }

        @Test("the phase follows what the page reports")
        func followsThePage() {
            let (model, _) = model()
            #expect(model.phase == .loading)

            model.receive(.ready)
            #expect(model.phase == .loading)
            model.receive(.appState(.init(phase: .connecting, step: .session)))
            #expect(model.phase == .connecting(.session))
            model.receive(.appState(.init(phase: .live, daemonVersion: "1.11.0")))
            #expect(model.phase == .live)
            #expect(model.daemonVersion == "1.11.0")
        }

        /// Leaving is the page putting the robot to sleep, so the host asks and
        /// then waits for `embed:left` rather than tearing the page down under it.
        @Test("leaving a live app asks the page and waits for it to let go")
        func leaveWaitsForThePage() async {
            let (model, sent) = model()
            live(model)

            let leaving = Task { await model.leave() }
            while model.phase != .leaving {
                await Task.yield()
            }
            #expect(sent.scripts.count == 1)
            #expect(sent.scripts.first?.contains(#""type":"host:leaving""#) == true)
            #expect(sent.scripts.first?.hasPrefix("window.postMessage(") == true)

            model.receive(.left)
            await leaving.value
            #expect(model.phase == .left)
        }

        /// **The duration is the assertion** (project rule 7): a page that never
        /// answers and one that answers end in the same `.left`, and only the
        /// clock tells a wait that was bounded from one that was skipped.
        @Test("a page that never answers is let go at the deadline")
        func leaveTimesOut() async {
            let (model, _) = model(leaveTimeout: .milliseconds(300))
            live(model)

            let start = ContinuousClock.now
            await model.leave()

            #expect(model.phase == .left)
            #expect(start.duration(to: .now) >= .milliseconds(250))
        }

        @Test("a page that never reached the robot is let go at once, with nothing sent")
        func leavesALoadingPageAtOnce() async {
            let (model, sent) = model(leaveTimeout: .seconds(30))

            let start = ContinuousClock.now
            await model.leave()

            #expect(model.phase == .left)
            #expect(sent.scripts.isEmpty)
            #expect(start.duration(to: .now) < .seconds(5))
        }

        @Test("a second Close joins the first wait rather than ending it early")
        func secondCloseJoins() async {
            let (model, sent) = model()
            live(model)

            let first = Task { await model.leave() }
            while model.phase != .leaving {
                await Task.yield()
            }
            let second = Task { await model.leave() }
            await Task.yield()

            model.receive(.left)
            await first.value
            await second.value
            #expect(sent.scripts.count == 1)
            #expect(model.phase == .left)
        }

        @Test("a late live report cannot reopen an app being closed")
        func ignoresLateLive() async {
            let (model, _) = model()
            live(model)
            let leaving = Task { await model.leave() }
            while model.phase != .leaving {
                await Task.yield()
            }

            model.receive(.appState(.init(phase: .live)))
            #expect(model.phase == .leaving)

            model.receive(.left)
            await leaving.value
        }

        @Test("the app's own Exit asks the screen to close")
        func requestLeave() {
            let (model, _) = model()
            live(model)

            model.receive(.requestLeave)

            #expect(model.closeRequested)
        }

        @Test("only a fatal error ends the app")
        func fatalErrors() {
            let (model, _) = model()
            live(model)

            model.receive(.error(message: "slow link", fatal: false))
            #expect(model.phase == .live)

            model.receive(.error(message: "robot busy", fatal: true))
            #expect(model.phase == .failed("robot busy"))
        }

        @Test("a page that dies while leaving still lets the wait end")
        func pageDiesWhileLeaving() async {
            let (model, _) = model()
            live(model)
            let leaving = Task { await model.leave() }
            while model.phase != .leaving {
                await Task.yield()
            }

            model.pageFailed("crashed")
            await leaving.value

            #expect(model.phase == .left)
        }
    }
#endif
