import Foundation
import Observation
import ReachyKit

/// The phase 0.4 device check: manual connect + state-stream counter with live frequency.
@MainActor
@Observable
final class DeviceCheckModel {
    var host: String = UserDefaults.standard.string(forKey: "lastHost") ?? "127.0.0.1" {
        didSet { UserDefaults.standard.set(host, forKey: "lastHost") }
    }

    private(set) var handshakeSummary: String?
    private(set) var lastError: String?
    private(set) var isStreaming = false
    private(set) var frameCount = 0
    private(set) var hertz: Double = 0
    private(set) var streamDiagnostics = StateStreamDiagnostics()

    var invalidFrameCount: Int {
        streamDiagnostics.decodeFailures + streamDiagnostics.unsupportedFrames
    }

    private var streamTask: Task<Void, Never>?
    private var arrivals: [ContinuousClock.Instant] = []

    func connect() async {
        lastError = nil
        handshakeSummary = nil
        guard let address = RobotAddress(parsing: host) else {
            lastError = "Invalid address: \(host)"
            return
        }
        do {
            let connection = try RobotConnection(address: address)
            let handshake = try await connection.handshake()
            handshakeSummary = """
            name: \(handshake.identity.name ?? "—")
            daemon: \(handshake.identity.daemonVersion ?? "—")
            hardware: \(handshake.identity.hardwareID ?? "— (sim)")
            state: \(handshake.status.state)
            sim: \(handshake.status.simulationEnabled?.description ?? "—")
            """
        } catch {
            lastError = "\(error)"
        }
    }

    func toggleStream() {
        if isStreaming {
            streamTask?.cancel()
            streamTask = nil
            isStreaming = false
            return
        }
        guard let address = RobotAddress(parsing: host) else {
            lastError = "Invalid address: \(host)"
            return
        }
        do {
            let client = try StateStreamClient(address: address)
            frameCount = 0
            arrivals = []
            streamDiagnostics = .init()
            isStreaming = true
            streamTask = Task { [weak self] in
                for await update in client.updates() {
                    guard let self else { break }
                    streamDiagnostics = update.diagnostics
                    if update.state != nil {
                        recordFrame()
                    }
                }
            }
        } catch {
            lastError = "\(error)"
        }
    }

    #if DEBUG
        /// Frozen device-check state for previews. Here rather than beside the previews because every
        /// field below is `private(set)`.
        static func preview(
            host: String = "192.168.1.42",
            handshakeSummary: String? = nil,
            lastError: String? = nil,
            isStreaming: Bool = false,
            frameCount: Int = 0,
            hertz: Double = 0,
            diagnostics: StateStreamDiagnostics = .init()
        ) -> DeviceCheckModel {
            let model = DeviceCheckModel()
            model.host = host
            model.handshakeSummary = handshakeSummary
            model.lastError = lastError
            model.isStreaming = isStreaming
            model.frameCount = frameCount
            model.hertz = hertz
            model.streamDiagnostics = diagnostics
            return model
        }

        static let previewHandshake = """
        name: Reachy Mini
        daemon: 1.9.0
        hardware: — (sim)
        state: running
        sim: true
        """
    #endif

    private func recordFrame() {
        frameCount += 1
        let now = ContinuousClock.now
        arrivals.append(now)
        // Sliding 2-second window; rate over the actual observed span
        arrivals.removeAll { $0 < now - .seconds(2) }
        if let first = arrivals.first, arrivals.count >= 2 {
            let span = first.duration(to: now)
            let seconds = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
            if seconds > 0 {
                hertz = Double(arrivals.count - 1) / seconds
            }
        }
    }
}
