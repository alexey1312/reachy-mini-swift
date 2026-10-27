import Foundation
@testable import ReachyKit
import Testing

/// The Hub pages `/api/spaces` with an RFC 8288 `Link` header, and daemon 1.13.0
/// follows it past the first 500 (pollen-robotics/reachy_mini#1420).
@Suite("Hub catalogue paging")
struct HubAppCataloguePagingTests {
    @Test("the next page is read off the Link header")
    func readsNext() {
        let header = #"<https://huggingface.co/api/spaces?filter=x&cursor=abc>; rel="next""#

        #expect(HubAppCatalogue.nextPage(in: header)?.absoluteString
            == "https://huggingface.co/api/spaces?filter=x&cursor=abc")
    }

    @Test("a header with other relations finds the next one among them")
    func findsNextAmongOthers() {
        let header = #"<https://example.com/a>; rel="prev", <https://example.com/b>; rel = "next""#

        #expect(HubAppCatalogue.nextPage(in: header)?.absoluteString == "https://example.com/b")
    }

    @Test("no header, or no next, is the last page", arguments: [nil, "", #"<https://example.com/a>; rel="prev""#])
    func lastPage(header: String?) {
        #expect(HubAppCatalogue.nextPage(in: header) == nil)
    }
}
