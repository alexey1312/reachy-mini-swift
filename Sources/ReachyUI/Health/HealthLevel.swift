import ReachyDesign

/// How worrying a reading is, in the three steps a colour can actually convey.
///
/// The thresholds are properties of the hardware the robot runs on, not of taste,
/// and they are here rather than inline in the view so they can be asserted: a
/// number that decides a colour is logic, and the reference images cannot tell a
/// wrong threshold from a right one.
enum HealthLevel: Sendable, Equatable {
    case normal
    case elevated
    case critical

    var tone: Tone {
        switch self {
        case .normal: .quiet
        case .elevated: .warning
        case .critical: .danger
        }
    }
}

extension HealthLevel {
    /// A processor is not in trouble for being busy — that is what it is for. Only
    /// sustained saturation, where new work has to queue, is worth a colour.
    static func cpu(_ percent: Double) -> HealthLevel {
        switch percent {
        case ..<75: .normal
        case ..<92: .elevated
        default: .critical
        }
    }

    /// Measured against `MemAvailable`, so this is real pressure rather than the
    /// page cache Linux fills with whatever is spare.
    static func memory(_ percent: Double) -> HealthLevel {
        switch percent {
        case ..<75: .normal
        case ..<90: .elevated
        default: .critical
        }
    }

    /// The Raspberry Pi 5 the robot runs on begins soft-throttling at 80 °C and
    /// hard-throttles at 85. So `elevated` here means "about to lose performance",
    /// which is a warning worth giving before the control loop starts missing its
    /// period rather than after.
    static func temperature(_ celsius: Double) -> HealthLevel {
        switch celsius {
        case ..<70: .normal
        case ..<80: .elevated
        default: .critical
        }
    }

    /// Against the loop's own nominal rate rather than an absolute figure: what
    /// matters is the shortfall.
    ///
    /// **The nominal was 100 Hz and that was wrong by a factor of two, which a
    /// healthy robot reported as `critical`.** `backend.py` sets
    /// `self.control_loop_frequency = 50.0` and nothing exposes it, so the constant
    /// had to be read out of the daemon; a real Reachy Mini Wireless answers 49.59 Hz,
    /// which against 100 scores 0.496 and painted the row red. No test and no
    /// reference image could have caught it — both were written against the same
    /// wrong number. See `HealthMetric.nominalFrequencyHz`.
    static func frequency(_ hertz: Double, nominal: Double = HealthMetric.nominalFrequencyHz) -> HealthLevel {
        guard nominal > 0 else { return .normal }
        // Explicit `return`: the guard above makes this a two-statement body, and the
        // implicit-return rule only covers a body that is one expression.
        return switch hertz / nominal {
        case 0.9...: .normal
        case 0.7...: .elevated
        default: .critical
        }
    }
}

/// The fixed ranges the sparklines are drawn against.
///
/// Deliberately not auto-scaled to the data. A sparkline that fits its own extremes
/// turns a 0.3% wobble in memory into a mountain range and a processor pinned at
/// 100% into a flat line — both of which read as the opposite of what happened.
enum HealthMetric {
    /// What the robot's control loop runs at when nothing is wrong.
    ///
    /// **50, read out of `backend.py` (`self.control_loop_frequency = 50.0`) and
    /// confirmed against a real Reachy Mini Wireless at 49.59 Hz.** The daemon
    /// hard-codes it and exposes it through no route, so there is nothing to ask —
    /// only the measured rate comes back, and judging it needs this number.
    static let nominalFrequencyHz: Double = 50

    static let percent: ClosedRange<Double> = 0 ... 100
    /// From room temperature to past the throttling point, so headroom is visible.
    static let temperature: ClosedRange<Double> = 20 ... 90

    /// A loop cannot meaningfully outrun its own target, so the fastest rate seen
    /// this session *is* the nominal — with the daemon's constant as a floor.
    ///
    /// That floor is what makes the calibration safe: taking the observed maximum
    /// alone would treat a robot that has been degraded since the screen opened as
    /// perfectly healthy, because its worst rate would also be its best. And the
    /// observed maximum is what keeps a future daemon that retunes its period from
    /// turning the row red for running faster than this constant knows about.
    static func nominalFrequency(observed: Double?) -> Double {
        max(nominalFrequencyHz, observed ?? 0)
    }

    /// A little headroom over the nominal, so a loop holding its rate does not draw
    /// itself hard against the top edge of the chart.
    static func frequencyDomain(nominal: Double) -> ClosedRange<Double> {
        0 ... nominal * 1.15
    }
}
