import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

@Suite("FullState decoding")
struct FullStateDecodingTests {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    @Test("decodes a realistic state payload with unknown future fields")
    func decodesFixture() throws {
        let data = try fixtureData("full_state")
        let state = try JSONCodec.daemon.decode(Components.Schemas.FullState.self, from: data)

        #expect(state.controlMode == .enabled)
        #expect(state.bodyYaw == 0.25)
        #expect(state.headPose?.value1?.yaw == -0.3)
        #expect(state.antennasPosition == [0.1, -0.1])
        // passive_joints is null with the default kinematics engine
        #expect(state.passiveJoints == nil)
        #expect(state.doa?.speechDetected == true)
        #expect(state.doa?.angle == 1.5707)
    }

    @Test("decodes a frame recorded from a real simulated daemon (v1.9.0)")
    func decodesRecordedFrame() throws {
        let data = try fixtureData("full_state_recorded")
        let state = try JSONCodec.daemon.decode(Components.Schemas.FullState.self, from: data)

        #expect(state.controlMode == .enabled)
        #expect(state.headPose?.value1 != nil)
        #expect(state.antennasPosition?.count == 2)
        #expect(state.timestamp != nil)
    }

    @Test("schema type changes fail explicitly")
    func rejectsIncompatibleTypeChange() {
        let data = Data(#"{"body_yaw":"quarter turn"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONCodec.daemon.decode(Components.Schemas.FullState.self, from: data)
        }
    }

    @Test("all-null payload decodes to empty state (graceful degradation)")
    func decodesEmpty() throws {
        let state = try JSONCodec.daemon.decode(Components.Schemas.FullState.self, from: Data("{}".utf8))
        #expect(state.controlMode == nil)
        #expect(state.headPose == nil)
    }
}
