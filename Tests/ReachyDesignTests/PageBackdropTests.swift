@testable import ReachyDesign
import SwiftUI
import Testing

/// A `.page` surface paints what its page declares, and only a grouped page declares
/// anything. The default is what keeps every other page — and the gallery — on the
/// plain background `.page` always had.
@Suite("Page backdrop")
struct PageBackdropTests {
    @Test("a page that declares nothing is plain")
    func defaultIsPlain() {
        #expect(EnvironmentValues().reachyPageBackdrop == .plain)
    }
}
