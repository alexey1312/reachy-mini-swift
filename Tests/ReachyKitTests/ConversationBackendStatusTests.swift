import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

/// `conversation.status` as the conversation app answers it, decoded through the
/// codec the RPC client uses.
@Suite("Conversation backend status")
struct ConversationBackendStatusTests {
    private func decode(_ json: String) throws -> ConversationBackendStatus {
        try JSONCodec.daemon.decode(ConversationBackendStatus.self, from: Data(json.utf8))
    }

    @Test("a backend that says it is not connected reads as not connected")
    func reportsAConnectingBackend() throws {
        let status = try decode("""
        {"can_proceed": true, "backend_connected": false,
         "backend_connection_state": "connecting", "backend_error": null}
        """)
        #expect(status.canProceed)
        #expect(status.isConnected == false)
        #expect(status.connectionState == "connecting")
    }

    /// The screen goes live only on a connected backend, so a missing flag must not
    /// read as "not connected" — that would hold a working app on "preparing" for the
    /// whole startup budget and then call it not configured.
    @Test("an answer without the flag reads as connected")
    func missingFlagIsConnected() throws {
        let status = try decode(#"{"can_proceed": true}"#)
        #expect(status.isConnected)
    }
}
