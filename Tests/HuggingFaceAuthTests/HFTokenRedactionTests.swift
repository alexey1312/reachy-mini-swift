import Foundation
@testable import HuggingFaceAuth
import Testing

@Suite("A printed token is redacted")
struct HFTokenRedactionTests {
    private let token = HFToken(
        accessToken: "hf_access_secret",
        refreshToken: "hf_refresh_secret",
        username: "alexey1312"
    )

    @Test("no way of printing a token shows either half of it")
    func printsNoSecret() {
        var dumped = ""
        dump(token, to: &dumped)

        for printed in [String(describing: token), String(reflecting: token), "\(token)", dumped] {
            #expect(!printed.contains("secret"))
            #expect(printed.contains("alexey1312"))
        }
    }
}
