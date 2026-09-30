import Foundation

/// A failure the robot reported as an `ERROR: …` string on the response
/// characteristic. Every case here is a documented string from `bluetooth_service.py`.
public enum BLECommandError: Error, Equatable, Sendable {
    /// No live PIN session — send `PIN_…` again.
    case notAuthenticated
    case incorrectPIN
    /// The wrong-PIN throttle is running. It survives a BLE disconnect, so reconnecting
    /// does not clear it; the remaining seconds are the only useful thing to show.
    case lockedOut(seconds: Int)
    /// The sealed payload would not open. Usually a wrong PIN, but also a `kid` older
    /// than the robot's 600 s key rotation — retry once with a fresh key exchange
    /// before blaming the PIN.
    case badCredentials
    /// An `nmcli` operation is already in flight (daemon 409).
    case busy
    case unknownSSID
    case cannotForgetHotspot
    /// The BLE service is up but the daemon behind it is not answering on localhost.
    case daemonUnreachable
    case invalidPayload
    case other(String)
    /// `SET_NAME` was refused by the daemon's own validation (its 422): empty, or over
    /// 64 characters. Appended, so the cases before it keep their numbers.
    case invalidName

    /// The reply is a bare string with no code, so matching is on the text the robot
    /// actually emits.
    static func parse(_ message: String) -> BLECommandError {
        if let seconds = lockoutSeconds(in: message) {
            return .lockedOut(seconds: seconds)
        }
        if let known = exactReplies[message] {
            return known
        }
        if message.hasPrefix("Invalid payload") || message.hasPrefix("Missing field") {
            return .invalidPayload
        }
        return .other(message)
    }

    /// The replies the robot words the same way every time. A table rather than a
    /// `switch`, which crossed SwiftLint's complexity limit at the tenth string.
    private static let exactReplies: [String: BLECommandError] = [
        "Not connected. Please authenticate first.": .notAuthenticated,
        "Incorrect PIN": .incorrectPIN,
        "Bad credentials (wrong PIN?)": .badCredentials,
        "Busy": .busy,
        "Unknown ssid": .unknownSSID,
        "Cannot forget hotspot": .cannotForgetHotspot,
        "Daemon unreachable": .daemonUnreachable,
        "Invalid name": .invalidName,
        "Missing name": .invalidName,
    ]

    /// `Too many attempts. Try again in 40s.`
    private static func lockoutSeconds(in message: String) -> Int? {
        guard message.hasPrefix("Too many attempts") else { return nil }
        let digits = message.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }
}

extension BLECommandError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: "The robot needs its PIN again."
        case .incorrectPIN: "That PIN doesn't match."
        case let .lockedOut(seconds): "Too many wrong PINs. Try again in \(seconds) s."
        case .badCredentials: "The robot could not read the Wi-Fi password. Check the PIN."
        case .busy: "The robot is busy with another network operation."
        case .unknownSSID: "The robot doesn't know that network."
        case .cannotForgetHotspot: "The robot's own hotspot can't be removed."
        case .daemonUnreachable: "The robot's software isn't responding."
        case .invalidPayload: "The robot rejected the request as malformed."
        case let .other(text): text
        case .invalidName: "The robot did not accept that name. Use 1 to 64 characters."
        }
    }
}

/// One parsed reply from the response characteristic.
public enum BLEReply: Equatable, Sendable {
    case pong
    /// `OK: …` — the trailing text, e.g. `Connected` or `Named kitchen-reachy`.
    case ok(String)
    /// The robot did not recognise the command and echoed it back.
    case echo(String)
    /// A JSON document or a bare payload such as the scan result.
    case payload(String)
    case failure(BLECommandError)

    /// The synchronous ack a proxied command answers with before doing any work. The
    /// real result arrives later as a notification, so this value is never a result.
    public static let workingAck = "OK: working"

    public var isWorkingAck: Bool {
        self == .ok("working")
    }

    /// The reply's text, with the robot's own error thrown rather than returned.
    public func value() throws -> String {
        switch self {
        case let .failure(error):
            throw error
        // The robot echoes back anything it does not recognise, which means this build
        // and that daemon disagree about the command set.
        case let .echo(command):
            throw BLECommandError.other("The robot did not understand “\(command)”.")
        case .pong:
            return "PONG"
        case let .ok(text), let .payload(text):
            return text
        }
    }

    /// Non-nil for `.payload`, and for `.ok` whose text is itself the answer.
    public var text: String? {
        switch self {
        case let .payload(text), let .ok(text), let .echo(text): text
        case .pong: "PONG"
        case .failure: nil
        }
    }
}

public enum BLEResponseParser {
    public static func parse(_ raw: String) -> BLEReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "PONG" {
            return .pong
        }
        if let body = text.dropPrefix("ERROR: ") {
            return .failure(.parse(body))
        }
        if let body = text.dropPrefix("OK: ") {
            return .ok(body)
        }
        if let body = text.dropPrefix("ECHO: ") {
            return .echo(body)
        }
        // Verbatim, unlike every case above. This is where a `JOURNAL_READ` lands, and
        // its trailing newline is the only thing saying the last line is complete —
        // trimming it makes `BLEJournalReader` hold that line back and glue it to the
        // next chunk, so every read boundary corrupts a line. JSON payloads do not care.
        return .payload(raw)
    }

    public static func parse(_ data: Data) -> BLEReply {
        guard let text = String(bytes: data, encoding: .utf8) else {
            return .failure(.other("The robot sent a reply this app could not read."))
        }
        return parse(text)
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
