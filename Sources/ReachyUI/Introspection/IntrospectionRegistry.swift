import SwiftUI

#if DEBUG
    /// Where a screen that owns its model leaves the model for the introspection tree.
    ///
    /// The root owns the session and the router, and the tree reads those directly.
    /// The connect gate's model belongs to `ConnectionScreen`, so the screen hands it
    /// over when it appears. The reference is weak: the model goes away with the
    /// screen's `@State`, and the tree then has no gate to show.
    @MainActor
    final class IntrospectionRegistry {
        weak var gate: ConnectGateModel?
    }

    private struct ReachyIntrospectionKey: EnvironmentKey {
        static let defaultValue: IntrospectionRegistry? = nil
    }

    extension EnvironmentValues {
        /// Absent in previews, in snapshots and in every run with no
        /// `--reachy-introspect`, where nothing reads what a screen would register.
        var reachyIntrospection: IntrospectionRegistry? {
            get { self[ReachyIntrospectionKey.self] }
            set { self[ReachyIntrospectionKey.self] = newValue }
        }
    }

    private struct IntrospectedGate: ViewModifier {
        let model: ConnectGateModel
        @Environment(\.reachyIntrospection) private var registry

        func body(content: Content) -> some View {
            content.onAppear { registry?.gate = model }
        }
    }
#endif

extension View {
    /// Makes the gate's model readable through the introspection tree.
    /// Nothing in a Release build, and no pixel in any build.
    func introspected(_ gate: ConnectGateModel) -> some View {
        #if DEBUG
            modifier(IntrospectedGate(model: gate))
        #else
            self
        #endif
    }
}
