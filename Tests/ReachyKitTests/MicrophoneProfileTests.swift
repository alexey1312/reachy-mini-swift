@testable import ReachyKit
import Testing

/// The register sets and the readback that names them.
///
/// `matching` is the whole reason a profile can be *shown* rather than only written,
/// and it compares floats that a USB round trip has already rounded — the values in
/// `readback` are what a Wireless unit on firmware 2.1.2 actually answered.
@Suite("Microphone profiles")
struct MicrophoneProfileTests {
    /// Every profile writes the same registers, so switching leaves nothing behind
    /// from the profile before it. A profile that named fewer would silently keep a
    /// value the reader thinks they replaced.
    @Test func everyProfileWritesTheSameRegisters() {
        let expected = Set(MicrophoneProfile.standard.parameters.map(\.name))
        for profile in MicrophoneProfile.allCases {
            #expect(Set(profile.parameters.map(\.name)) == expected)
        }
        #expect(expected.count == MicrophoneProfile.standard.parameters.count)
    }

    /// The daemon types its request body as `list[float]`, so an integer register
    /// reaches `struct.pack("i", 1.0)` and throws — the write is refused and the call
    /// answers `{"applied": false}`. A profile that named one could never be applied.
    @Test func noProfileWritesAnIntegerRegister() {
        let integerRegisters: Set = [
            "PP_AGCONOFF", "PP_LIMITONOFF", "PP_ECHOONOFF", "PP_NLATTENONOFF",
            "PP_DTSENSITIVE", "AEC_HPFONOFF", "AEC_FIXEDBEAMSONOFF",
        ]
        for profile in MicrophoneProfile.allCases {
            #expect(Set(profile.parameters.map(\.name)).isDisjoint(with: integerRegisters))
        }
    }

    @Test func eachProfileMatchesItsOwnValues() {
        for profile in MicrophoneProfile.allCases {
            #expect(MicrophoneProfile.matching(profile.parameters) == profile)
        }
    }

    /// The board rounds a float on the way back, so an exact comparison would report
    /// every robot as hand-tuned.
    @Test func matchesValuesTheBoardRounded() {
        let readback = [
            AudioParameter("PP_AGCDESIREDLEVEL", [0.0044999998062849045]),
            AudioParameter("PP_AGCMAXGAIN", [64.0]),
            AudioParameter("PP_LIMITPLIMIT", [0.4699999988079071]),
            AudioParameter("PP_MIN_NS", [0.15000000596046448]),
            AudioParameter("PP_MIN_NN", [0.5099999904632568]),
        ]
        #expect(MicrophoneProfile.matching(readback) == .standard)
    }

    @Test func namesNoProfileForABoardTunedByHand() {
        var tuned = MicrophoneProfile.standard.parameters
        tuned[0] = AudioParameter("PP_AGCDESIREDLEVEL", [0.03])
        #expect(MicrophoneProfile.matching(tuned) == nil)
    }

    /// A short read is not a match: a register the daemon refused to answer would
    /// otherwise leave the screen naming a profile the board does not hold.
    @Test func namesNoProfileWhenARegisterIsMissing() {
        let partial = Array(MicrophoneProfile.standard.parameters.dropLast())
        #expect(MicrophoneProfile.matching(partial) == nil)
    }
}
