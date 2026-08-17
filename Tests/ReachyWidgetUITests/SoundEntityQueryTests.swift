import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// The sound picker, and the one property that makes a saved shortcut survive.
@Suite("SoundEntityQuery", .timeLimit(.minutes(1)))
struct SoundEntityQueryTests {
    private func query(_ names: [String]) -> SoundEntityQuery {
        SoundEntityQuery(names: { names })
    }

    /// **Reads nothing at all**, the property `MoveEntity` has and `RobotAppEntity`
    /// cannot: the filename is the whole address, so an entity is rebuilt from the id
    /// with no library, no cache and no robot.
    @Test("a saved selection resolves with an empty library")
    func resolvesWithNothingStored() async throws {
        let resolved = try await query([]).entities(for: ["airhorn.wav", "tada.m4a"])

        #expect(resolved.map(\.id) == ["airhorn.wav", "tada.m4a"])
    }

    /// WidgetKit prunes a configuration whose entities come back short, so a sound the
    /// robot has forgotten must still resolve here. The refusal belongs to the moment the
    /// button is pressed, where there is somewhere to say it — `RobotSoundPlayer`.
    @Test("no identifier is ever dropped")
    func neverDropsAnIdentifier() async throws {
        let resolved = try await query(["airhorn.wav"]).entities(for: ["gone.wav"])

        #expect(resolved.map(\.id) == ["gone.wav"])
    }

    @Test("the picker offers this device's library")
    func suggestsTheLibrary() async throws {
        let suggested = try await query(["airhorn.wav", "tada.m4a"]).suggestedEntities()

        #expect(suggested.map(\.title) == ["airhorn", "tada"])
    }

    /// Siri hands over the words it heard, and a sound is addressed by a filename — so
    /// the match is against the spoken form as well as the name on disk.
    @Test("a spoken name matches the sound it names")
    func matchesTheSpokenForm() async throws {
        let query = query(["air_horn.wav", "tada.m4a"])

        #expect(try await query.entities(matching: "air horn").map(\.id) == ["air_horn.wav"])
        #expect(try await query.entities(matching: "tada.m4a").map(\.id) == ["tada.m4a"])
        #expect(try await query.entities(matching: "  ").count == 2)
        #expect(try await query.entities(matching: "nothing").isEmpty)
    }

    /// One spelling of a sound's name, shared by the screen, the entity, the control's
    /// label and this matcher — four places that must not disagree.
    @Test("the display name drops the extension and reads the separators as spaces")
    func spellsTheNameOnce() {
        #expect(SoundEntity(filename: "air_horn.wav").title == "air horn")
        #expect(SoundEntity(filename: "door-bell.mp3").title == "door bell")
        #expect(SoundEntity(filename: "no-extension").title == "no extension")
        #expect(RobotSound(filename: "tada.m4a").displayName == "tada")
    }
}
