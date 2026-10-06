@testable import ReachyDesign
import Testing

/// Which tiers carry the minimum target in their label. A tier that draws no shape
/// around its label has nothing else to tap, so a new tier that forgets this ships a
/// way-out the height of one line of text.
@Suite("Button emphasis")
struct ButtonEmphasisTests {
    @Test("a quiet label is at least one minimum target tall")
    func quietCarriesTheTarget() {
        #expect(ButtonEmphasis.quiet.minimumLabelHeight == Metrics.minimumHitTarget)
    }

    @Test("a tier that draws a capsule leaves the height to the capsule", arguments: [
        ButtonEmphasis.prominent, .standard, .destructive,
    ])
    func capsuleTiersAddNoHeight(_ emphasis: ButtonEmphasis) {
        #expect(emphasis.minimumLabelHeight == nil)
    }

    @Test("the minimum target is Apple's 44 points")
    func minimumIsFortyFour() {
        #expect(Metrics.minimumHitTarget == 44)
    }
}
