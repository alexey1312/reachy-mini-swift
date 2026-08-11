import SwiftUI
@preconcurrency import WebRTC

/// Renders a remote `RTCVideoTrack` via Metal (`RTCMTLVideoView` / `RTCMTLNSVideoView`).
///
/// **It fills the space it is given and never proposes one of its own.** The
/// Metal views report the *stream's* frame size as their intrinsic content size,
/// and a representable with no `sizeThatFits` forwards that straight through
/// `systemLayoutSizeFitting` — so the view sizes itself to whatever resolution
/// WebRTC happens to be sending, and any parent that centres its content (both
/// hosts do: `ViewportView` and `PreviewScene.pane` each apply
/// `.frame(maxWidth: .infinity, maxHeight: .infinity)`) then centres a picture
/// measured in bitrate. On a landscape iPhone that put a ~140 pt picture in the
/// middle of an 874 pt screen; in portrait the same intrinsic size overflowed the
/// width and was clipped, which read as full-bleed and is why this was reported as
/// a landscape bug rather than as the orientation-independent one it is.
///
/// **A second cause produced the same picture, and it is not in this file.** "Tiny
/// video in the middle of a landscape screen" was reported again after the above
/// was fixed, and `sizeThatFits` was innocent: `CameraViewport` hung its joystick
/// off a bottom `safeAreaInset`, which subtracts a fixed 172 pt from the rectangle
/// this view is handed — nothing out of a portrait iPhone's 874 pt, two thirds of a
/// landscape one's 402. Filling ~86 pt of height correctly looks exactly like
/// failing to fill 402. So measure the proposal this view receives before
/// suspecting what it does with one; the numbers are in `CameraViewport`.
///
/// Letterboxing stays the renderer's job — `videoContentMode` below, and
/// `RTCMTLVideoView` clears its own unfilled area.
public struct CameraVideoView {
    private let track: RTCVideoTrack?

    public init(track: RTCVideoTrack?) {
        self.track = track
    }

    /// A proposal with an unspecified or infinite dimension means nobody has
    /// decided how big this is yet, and a video renderer is in no position to
    /// answer — there is no size a stream *should* be. Zero lets the caller's own
    /// frame decide, which is what every call site here already brings.
    private static func resolved(_ proposal: ProposedViewSize) -> CGSize {
        let size = proposal.replacingUnspecifiedDimensions(by: .zero)
        return CGSize(
            width: size.width.isFinite ? size.width : 0,
            height: size.height.isFinite ? size.height : 0
        )
    }

    public final class Coordinator {
        fileprivate var current: RTCVideoTrack?

        fileprivate func attach(_ track: RTCVideoTrack?, renderer: RTCVideoRenderer) {
            guard track !== current else { return }
            current?.remove(renderer)
            track?.add(renderer)
            current = track
        }

        fileprivate func detach(renderer: RTCVideoRenderer) {
            current?.remove(renderer)
            current = nil
        }
    }
}

#if os(iOS)
    extension CameraVideoView: UIViewRepresentable {
        public func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        public func makeUIView(context _: Context) -> RTCMTLVideoView {
            let view = RTCMTLVideoView()
            view.videoContentMode = .scaleAspectFit
            return view
        }

        public func updateUIView(_ view: RTCMTLVideoView, context: Context) {
            context.coordinator.attach(track, renderer: view)
        }

        public func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView _: RTCMTLVideoView,
            context _: Context
        ) -> CGSize? {
            Self.resolved(proposal)
        }

        public static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
            coordinator.detach(renderer: view)
        }
    }
#else
    extension CameraVideoView: NSViewRepresentable {
        public func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        public func makeNSView(context _: Context) -> RTCMTLNSVideoView {
            RTCMTLNSVideoView()
        }

        public func updateNSView(_ view: RTCMTLNSVideoView, context: Context) {
            context.coordinator.attach(track, renderer: view)
        }

        public func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView _: RTCMTLNSVideoView,
            context _: Context
        ) -> CGSize? {
            Self.resolved(proposal)
        }

        public static func dismantleNSView(_ view: RTCMTLNSVideoView, coordinator: Coordinator) {
            coordinator.detach(renderer: view)
        }
    }
#endif
