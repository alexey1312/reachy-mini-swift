import ReachyDesign
import SwiftUI
import Testing

/// The numbers are the iPhone Duo simulator's (Xcode 27.1, iOS 27.1): an inner
/// display 951 × 669 pt in landscape, content 867 pt wide beside an 84 pt vertical
/// bar, and in book pose an active division at x 455.5, 40 pt wide with its margins.
@Suite("Fold insets")
struct FoldInsetsTests {
    private let content = CGSize(width: 867, height: 553)
    private let book = CGRect(x: 455.5, y: -82, width: 40, height: 669)

    @Test("no fold moves nothing")
    func noFold() {
        #expect(FoldInsets.clearing(nil, in: content, toward: .larger, minimumLength: 200) == EdgeInsets())
    }

    @Test("a fold outside the view moves nothing")
    func foldElsewhere() {
        let fold = CGRect(x: 900, y: 0, width: 40, height: 669)
        #expect(FoldInsets.clearing(fold, in: content, toward: .larger, minimumLength: 200) == EdgeInsets())
    }

    @Test("book pose keeps the picture on the leading side, short of the fold's frame")
    func bookLeading() {
        let insets = FoldInsets.clearing(book, in: content, toward: .leadingOrTop, minimumLength: 200)
        #expect(insets == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 867 - 455.5))
    }

    @Test("a read-only block takes the larger side, which is the leading one here")
    func bookLarger() {
        let insets = FoldInsets.clearing(book, in: content, toward: .larger, minimumLength: 200)
        #expect(insets.trailing == 867 - 455.5)
        #expect(insets.leading == 0)
    }

    @Test("when the trailing side is larger, a read-only block goes there")
    func bookTrailingLarger() {
        let fold = CGRect(x: 200, y: 0, width: 40, height: 553)
        let insets = FoldInsets.clearing(fold, in: content, toward: .larger, minimumLength: 150)
        #expect(insets == EdgeInsets(top: 0, leading: 240, bottom: 0, trailing: 0))
    }

    @Test("tabletop keeps the picture above the fold")
    func tabletopTop() {
        let portrait = CGSize(width: 585, height: 869)
        let fold = CGRect(x: 0, y: 455.5, width: 585, height: 40)
        let insets = FoldInsets.clearing(fold, in: portrait, toward: .leadingOrTop, minimumLength: 200)
        #expect(insets == EdgeInsets(top: 0, leading: 0, bottom: 869 - 455.5, trailing: 0))
    }

    @Test("a side too short for the content leaves it where it was")
    func tooShort() {
        let narrow = CGSize(width: 380, height: 553)
        let fold = CGRect(x: -31.5, y: 0, width: 40, height: 669)
        #expect(FoldInsets.clearing(fold, in: narrow, toward: .leadingOrTop, minimumLength: 200) == EdgeInsets())
    }
}
