import Foundation
@testable import ReachyScene
import RealityKit
import Testing

/// A long telepresence session on a phone throttles, and the viewer should give
/// something up before the system takes the frame rate instead. These pin *what* it
/// gives up and *when* — the wiring that notices the heat is `NotificationCenter` and
/// not worth a test of its own.
@Suite("Scene thermal policy")
struct SceneThermalPolicyTests {
    /// `.fair` is ordinary rather than a warning: a phone doing steady work sits there
    /// for minutes. Reacting to it would make the viewer flicker between two
    /// appearances for no thermal benefit.
    @Test("ordinary warmth changes nothing")
    func warmthIsNotThrottling() {
        #expect(SceneThermalPolicy.quality(for: .nominal) == .full)
        #expect(SceneThermalPolicy.quality(for: .fair) == .full)
    }

    /// `.serious` is where the system has already begun throttling and says so.
    @Test("real throttling gives up shadows")
    func throttlingReduces() {
        #expect(SceneThermalPolicy.quality(for: .serious) == .reduced)
        #expect(SceneThermalPolicy.quality(for: .critical) == .reduced)
    }
}

@MainActor
@Suite("Scene lighting under heat")
struct SceneLightingThermalTests {
    /// The component is the only honest signal — `light.shadow` reads back non-nil
    /// either way, which is what the rig's own test already records.
    private func shadowed(_ rig: Entity) -> [String] {
        rig.children
            .compactMap { $0 as? DirectionalLight }
            .filter { $0.components.has(DirectionalLightComponent.Shadow.self) }
            .map(\.name)
    }

    @Test("shadows can be taken away and given back on a rig that already exists")
    func shadowsAreReversible() {
        let rig = RobotSceneLighting.makeRig()
        #expect(shadowed(rig) == ["key"])

        RobotSceneLighting.setShadowsEnabled(false, in: rig)
        #expect(shadowed(rig).isEmpty)

        RobotSceneLighting.setShadowsEnabled(true, in: rig)
        #expect(shadowed(rig) == ["key"])
    }

    /// Only the key light ever had one, so nothing else may grow one on the way back.
    @Test("restoring shadows does not light up the fill and rim")
    func restoreTouchesOnlyTheKeyLight() {
        let rig = RobotSceneLighting.makeRig()
        RobotSceneLighting.setShadowsEnabled(false, in: rig)
        RobotSceneLighting.setShadowsEnabled(true, in: rig)
        #expect(shadowed(rig).count == 1)
    }
}
