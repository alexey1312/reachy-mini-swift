import ReachyKit
import SwiftUI

// `DeviceCheckView` lives in the ReachyMini app target, which neither the snapshot bundle nor the
// storybook can import. Both compile its two source files directly instead — see the source globs
// in `Apps/Project.swift`.

@MainActor
enum DeviceCheckPreviewScene {
    static func deviceCheck(_ model: DeviceCheckModel, discovery: RobotBrowser? = nil) -> some View {
        DeviceCheckView(
            model: model,
            discovery: discovery ?? .preview(names: []),
            browsesLiveNetwork: false
        )
    }
}

#Preview("Device check — searching") {
    DeviceCheckPreviewScene.deviceCheck(.preview())
}

#Preview("Device check — robots found") {
    DeviceCheckPreviewScene.deviceCheck(.preview(), discovery: .preview())
}

#Preview("Device check — permission denied") {
    DeviceCheckPreviewScene.deviceCheck(.preview(), discovery: .preview(names: [], permissionDenied: true))
}

#Preview("Device check — handshake done") {
    DeviceCheckPreviewScene.deviceCheck(.preview(handshakeSummary: DeviceCheckModel.previewHandshake))
}

#Preview("Device check — handshake failed") {
    DeviceCheckPreviewScene.deviceCheck(.preview(lastError: "Could not connect to the server."))
}

#Preview("Device check — streaming") {
    DeviceCheckPreviewScene.deviceCheck(.preview(
        handshakeSummary: DeviceCheckModel.previewHandshake,
        isStreaming: true,
        frameCount: 1247,
        hertz: 9.8
    ))
}
