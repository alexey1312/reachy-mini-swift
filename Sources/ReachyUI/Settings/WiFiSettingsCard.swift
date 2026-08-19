import ReachyDesign
import ReachyKit
import SwiftUI

/// What the robot is on, what it remembers, and why the last attempt failed.
///
/// Read-only apart from forgetting: joining a network is the provisioning flow's job, and
/// it works over Bluetooth as well, which is the case that actually needs it.
struct WiFiSettingsCard: View {
    let session: RobotSession

    @State private var status: WiFiStatus?
    @State private var joinError: String?
    @State private var loadFailure: String?
    @State private var busy = false
    @State private var confirmingForgetAll = false
    @Environment(\.reachyPreviewMode) private var previewMode

    init(session: RobotSession, status: WiFiStatus? = nil, joinError: String? = nil, loadFailure: String? = nil) {
        self.session = session
        _status = State(initialValue: status)
        _joinError = State(initialValue: joinError)
        _loadFailure = State(initialValue: loadFailure)
    }

    var body: some View {
        Section {
            LabeledContent(.reachy("Mode"), value: modeText)
            if let connected = status?.connected {
                LabeledContent(.reachy("Network"), value: connected)
            }
            if let joinError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(joinError)
                        .font(Typography.detail)
                        .foregroundStyle(Tone.warning.style)
                    Button(.reachy("Clear this error")) {
                        Task { await clearError() }
                    }
                    .buttonStyle(.borderless)
                }
            }
            ForEach(status?.known ?? [], id: \.self) { network in
                LabeledContent(network) {
                    Button(.reachy("Forget"), role: .destructive) {
                        Task { await forget(network) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                }
            }
            // `/wifi/forget_all` rather than a loop over the rows: the robot does
            // it in one `nmcli` operation, and the per-network route answers 409
            // while another one runs, so a loop would race itself.
            if let known = status?.known, known.count > 1 {
                Button(.reachy("Forget all"), role: .destructive) {
                    confirmingForgetAll = true
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            }
            if let loadFailure {
                Text(loadFailure)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
        } header: {
            Text(.reachy("Network"))
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Forgetting the network the robot is on takes it off this network at the next restart. The robot's own hotspot cannot be forgotten."
                )
            )
        }
        .task {
            guard !previewMode else { return }
            await load()
        }
        .confirmationDialog(
            .reachy("Forget every saved network?"),
            isPresented: $confirmingForgetAll,
            titleVisibility: .visible
        ) {
            Button(.reachy("Forget all"), role: .destructive) {
                Task { await forgetAll() }
            }
        } message: {
            Text(.reachy("The robot falls back to its own hotspot at the next restart."))
        }
    }

    private var modeText: String {
        switch status?.mode {
        case .wlan: String(localized: .reachy("On a network"))
        case .hotspot: String(localized: .reachy("Its own hotspot"))
        case .disconnected: String(localized: .reachy("Not connected"))
        case .busy: "Working…"
        case nil: status == nil ? "—" : "Unknown"
        }
    }

    private func load() async {
        do {
            status = try await session.wifiStatus()
            joinError = try await session.lastWiFiError()
            loadFailure = nil
        } catch {
            loadFailure.recordDaemonFailure(error)
        }
    }

    private func forget(_ ssid: String) async {
        busy = true
        defer { busy = false }
        do {
            try await session.forgetWiFi(ssid: ssid)
            await load()
        } catch {
            loadFailure.recordDaemonFailure(error)
        }
    }

    private func forgetAll() async {
        busy = true
        defer { busy = false }
        do {
            try await session.forgetAllWiFi()
            await load()
        } catch {
            loadFailure.recordDaemonFailure(error)
        }
    }

    private func clearError() async {
        do {
            try await session.resetWiFiError()
            joinError = nil
        } catch {
            loadFailure.recordDaemonFailure(error)
        }
    }
}
