#if os(iOS) || os(visionOS)
    import SwiftUI
    import UIKit

    /// The window scene one part of the tree is drawn in.
    ///
    /// **`UIApplication.shared.connectedScenes` cannot answer that once an app has
    /// two windows**, and on iPhone Duo and iPad it can: Split View puts two
    /// instances side by side, each in a scene of its own. `.first` is then an
    /// arbitrary one of them and `foregroundActive` matches both. So the root reads
    /// its own scene off the `UIView` it is hosted in and hands it down, and a
    /// question about "this window" — which way it is held, where a sign-in sheet
    /// belongs — is asked of the scene that drew the question.
    ///
    /// The scene is held weakly: a scene that disconnects must not outlive its
    /// window here. Reads go through `current`, which reads `generation`, so a view
    /// that asked before the reader attached is drawn again once it has.
    @MainActor
    @Observable
    final class WindowSceneHandle {
        @ObservationIgnored private weak var scene: UIWindowScene?
        private var generation = 0

        var current: UIWindowScene? {
            _ = generation
            return scene
        }

        /// The scene's own identity, which is a `String` and so `Sendable` —
        /// the shape a scene takes when it has to cross an isolation boundary.
        var identifier: String? {
            current?.session.persistentIdentifier
        }

        func attach(_ scene: UIWindowScene?) {
            guard scene !== self.scene else { return }
            self.scene = scene
            generation += 1
        }
    }

    /// A zero-size view whose only job is `didMoveToWindow`.
    private struct WindowSceneReader: UIViewRepresentable {
        let handle: WindowSceneHandle

        func makeUIView(context _: Context) -> ReaderView {
            ReaderView(handle: handle)
        }

        func updateUIView(_: ReaderView, context _: Context) {}

        final class ReaderView: UIView {
            private let handle: WindowSceneHandle

            init(handle: WindowSceneHandle) {
                self.handle = handle
                super.init(frame: .zero)
                isHidden = true
                isUserInteractionEnabled = false
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) is not supported")
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                handle.attach(window?.windowScene)
            }
        }
    }

    private struct WindowSceneKey: EnvironmentKey {
        static let defaultValue: WindowSceneHandle? = nil
    }

    extension EnvironmentValues {
        /// The scene this view's window belongs to, set once by `ReachyRootView`.
        /// `nil` outside a root, which is every preview and every capture.
        var windowScene: WindowSceneHandle? {
            get { self[WindowSceneKey.self] }
            set { self[WindowSceneKey.self] = newValue }
        }
    }

    extension View {
        /// Reads the scene this view is hosted in into `handle`, and publishes the
        /// handle to everything below — sheets included, because a sheet on iOS is
        /// presented in the same window scene as the view it hangs off.
        func readsWindowScene(into handle: WindowSceneHandle) -> some View {
            background {
                WindowSceneReader(handle: handle)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .environment(\.windowScene, handle)
        }
    }
#endif
