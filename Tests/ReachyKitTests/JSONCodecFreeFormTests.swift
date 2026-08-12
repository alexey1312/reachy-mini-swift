import Foundation
import OpenAPIRuntime
import ReachyJSON
import Testing

/// The gate any replacement JSON engine passes before it is considered.
///
/// Free-form JSON is most of what this app reads: `AppInfo.extra` is the Hugging
/// Face card verbatim, and `control_loop_stats` is the robot's own telemetry. Both
/// arrive as `OpenAPIObjectContainer`, which identifies a value by trying `Bool`,
/// then `Int`, then `Double` — and relies on `Int` *refusing* a fractional number.
/// A decoder that rounds instead reports 49.58 Hz as 49 and 0.0207 s as 0, with no
/// error anywhere. swift-yyjson 0.6.0 does exactly that; see ADR 0004.
@Suite("JSON codec: free-form values")
struct JSONCodecFreeFormTests {
    private func value(_ json: String, _ key: String) throws -> String {
        let container = try JSONCodec.daemon.decode(OpenAPIObjectContainer.self, from: Data(json.utf8))
        let raw = container.value[key] ?? nil
        return try String(describing: #require(raw))
    }

    @Test("a fractional number stays fractional")
    func keepsFractions() throws {
        #expect(try value(#"{"float": 1.5}"#, "float") == "1.5")
    }

    @Test("the robot's control loop stats survive to the last digit")
    func keepsTelemetry() throws {
        let json = """
        {"mean_control_loop_frequency": 49.58092675563731,
         "max_control_loop_interval": 0.020709514617919922,
         "nb_error": 0}
        """
        #expect(try value(json, "mean_control_loop_frequency") == "49.58092675563731")
        #expect(try value(json, "max_control_loop_interval") == "0.020709514617919922")
        #expect(try value(json, "nb_error") == "0")
    }

    @Test("an integer written as an exponent is still an integer")
    func keepsExponentIntegers() throws {
        #expect(try value(#"{"exp": 1e3}"#, "exp") == "1000")
    }

    /// Beyond `Double`'s exact range, so a decoder that routes every number through
    /// `Double` loses the last digit here.
    @Test("an integer past 2^53 keeps every digit")
    func keepsLargeIntegers() throws {
        #expect(try value(#"{"big": 9007199254740993}"#, "big") == "9007199254740993")
    }
}
