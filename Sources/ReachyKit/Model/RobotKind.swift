import Foundation

/// The robot family a central listing names.
///
/// One central now serves more than one family: a Micro Duck registers with
/// `kind: "microduck"` under the same Hugging Face account a Reachy Mini uses,
/// and a Reachy Mini daemon sends no kind at all. Central stores `meta` as the
/// robot sent it and classifies `kind` for its public counters alone
/// (`docs/META_CONTRACT.md` and `robot_kinds.py` in
/// `pollen-robotics/reachy_mini_central_signalling`), so the listing hands every
/// family to every client and the client has to sort them out. This reads `meta`
/// the way central's own classifier does.
public enum RobotKind: Sendable, Equatable {
    case reachyMini
    case microDuck
    /// A family this app does not know. The raw value is not kept: any signed-in
    /// account can register any `meta`, so it is untrusted text.
    case other

    /// Central's rule: `kind`, else its `robot_type` alias, else a Reachy Mini.
    /// A value counts only when it is a string with something other than white
    /// space in it — a decoder hands anything else over as `nil`.
    public init(kind: String?, robotType: String?) {
        guard let raw = [kind, robotType].lazy.compactMap(\.self).first(where: Self.isUsable) else {
            self = .reachyMini
            return
        }
        // Central refuses to normalise anything longer, and so does this.
        guard raw.unicodeScalars.count <= Self.maximumRawLength else {
            self = .other
            return
        }
        switch Self.compact(raw) {
        case "reachymini": self = .reachyMini
        case "microduck": self = .microDuck
        default: self = .other
        }
    }

    /// `ROBOT_KIND_MAX_RAW_LEN` in central.
    static let maximumRawLength = 64

    private static func isUsable(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Lower-cased, with every character outside `a-z0-9` removed, so `Micro-Duck`,
    /// `micro duck` and `Reachy Mini` land where central puts them.
    private static func compact(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.lowercased().unicodeScalars.filter { scalar in
            ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar)
        }))
    }
}

extension [CentralRobot] {
    /// The entries this app can drive. Every list of robots it reads from central
    /// passes through here, because each screen that shows one offers to connect,
    /// and a Micro Duck answers none of what a Reachy Mini does.
    var reachyMinis: [CentralRobot] {
        filter { $0.kind == .reachyMini }
    }
}
