import ReachyDesign
import ReachyKit

// For `PrivacySettingsButton` alone — the one deep link to the system's privacy
// settings, which used to be copied into this file with its own `#if os(iOS)`.
import ReachyUI
import SwiftUI

/// Phase 0.4 device-check screen: discovery, manual connect, stream counter.
/// Checklist it serves — see docs/research/phase0.md.
struct DeviceCheckView: View {
    @State private var model: DeviceCheckModel
    @State private var discovery: RobotBrowser
    /// ReachyUI's `\.reachyPreviewMode` is internal to that module, so this screen carries its own
    /// switch: a preview hands in a seeded browser and must not also start Bonjour.
    private let browsesLiveNetwork: Bool

    /// `nil` defaults rather than `DeviceCheckModel()`: a default argument is evaluated in a nonisolated
    /// context and both of these are main-actor isolated.
    @MainActor
    init(model: DeviceCheckModel? = nil, discovery: RobotBrowser? = nil, browsesLiveNetwork: Bool = true) {
        _model = State(initialValue: model ?? DeviceCheckModel())
        _discovery = State(initialValue: discovery ?? RobotBrowser())
        self.browsesLiveNetwork = browsesLiveNetwork
    }

    var body: some View {
        Form {
            discoverySection
            connectSection
            streamSection
        }
        .formStyle(.grouped)
        .onAppear {
            guard browsesLiveNetwork else { return }
            discovery.start()
        }
        .onDisappear { discovery.stop() }
    }

    private var discoverySection: some View {
        Section(.reachy("Discovery (Bonjour)")) {
            ForEach(Array(discovery.browserStates.sorted(by: { $0.key < $1.key })), id: \.key) { type, state in
                LabeledContent(type) {
                    Text(state).font(Typography.consoleLine)
                }
            }
            if discovery.permissionLooksDenied {
                Label(.reachy("Local Network permission denied"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.danger.style)
                PrivacySettingsButton(pane: .localNetwork)
            }
            if discovery.services.isEmpty {
                Text(.reachy("No robots found")).foregroundStyle(.secondary)
            }
            ForEach(discovery.services) { service in
                LabeledContent(service.name) {
                    Text(service.type).font(Typography.consoleLine)
                }
            }
            Button(.reachy("Restart discovery")) { discovery.start() }
        }
    }

    private var connectSection: some View {
        Section(.reachy("Connection")) {
            TextField(.reachy("Host (IP or name.local)"), text: $model.host)
                .autocorrectionDisabled()
            #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            #endif
            Button(.reachy("Connect (handshake)")) {
                Task { await model.connect() }
            }
            if let summary = model.handshakeSummary {
                Text(summary).font(Typography.consoleLine)
            }
            if let error = model.lastError {
                Text(error)
                    .font(Typography.consoleLine)
                    .foregroundStyle(Tone.danger.style)
            }
        }
    }

    private var streamSection: some View {
        Section(.reachy("State stream (10 Hz by default)")) {
            Button(model
                .isStreaming ? String(localized: .reachy("Stop stream")) : String(localized: .reachy("Start stream")))
            {
                model.toggleStream()
            }
            LabeledContent(.reachy("Frames")) { Text(.reachy("\(model.frameCount)")) }
            LabeledContent(.reachy("Rate")) { Text(String(format: "%.1f Hz", model.hertz)) }
            if model.streamDiagnostics.decodeFailures > 0 || model.streamDiagnostics.unsupportedFrames > 0 {
                Label(
                    .reachy("Invalid frames: \(model.invalidFrameCount)"),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(Tone.warning.style)
                if let failure = model.streamDiagnostics.lastFailureDescription {
                    Text(failure).font(Typography.consoleLine)
                }
            }
        }
    }
}
