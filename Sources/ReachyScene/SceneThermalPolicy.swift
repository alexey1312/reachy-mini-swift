import Foundation

/// How much the 3D viewer is allowed to spend on looking good.
public enum SceneQuality: Equatable, Sendable {
    case full
    /// Shadows off. The silhouette, the shading and the motion all survive; what goes
    /// is the one thing that costs fill rate and that nobody is looking at during a
    /// long telepresence session.
    case reduced
}

/// What the device's heat means for the viewer.
///
/// A pure mapping, kept apart from the entity tree it acts on so the rule is testable
/// without RealityKit having to render anything — the same division
/// `RunningAppActivityPlan` makes for a different framework.
///
/// **The threshold is `.serious`, not `.fair`.** `.fair` is ordinary: a phone doing
/// steady work sits there for minutes at a time, and dropping shadows every time it
/// warms slightly would make the viewer visibly flicker between two appearances for
/// no thermal benefit. `.serious` is where the system has already begun throttling and
/// says so.
public enum SceneThermalPolicy {
    public static func quality(for state: ProcessInfo.ThermalState) -> SceneQuality {
        switch state {
        case .nominal, .fair: .full
        case .serious, .critical: .reduced
        // `ThermalState` is not `@frozen`. A state Apple adds later is more likely to
        // be hotter than `.critical` than cooler than `.nominal`, so the safe reading
        // of an unknown one is "spend less".
        @unknown default: .reduced
        }
    }
}
