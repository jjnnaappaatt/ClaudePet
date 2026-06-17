import Foundation

/// The pet's ambient sky, derived from its mood (see `MetricsStore.weatherCondition`). The mascot's
/// face and its weather share one source of truth — `MascotEmotion` — so they can never disagree:
/// calm sun when idle, sun while there's headroom, clouds at mid-usage, rain/storm near a limit,
/// and a heavy storm with lightning at the edge.
public enum WeatherCondition: String, CaseIterable, Sendable {
    case clearSky      // idle / sleeping — calm, a gentle sun
    case sunny         // plenty of headroom (happy / celebrating)
    case cloudy        // mid usage (neutral, 50–80%) — a few drifting clouds
    case storm         // high usage (worried, 80–95%) — cloud + light rain
    case heavyStorm    // critical (alarmed, ≥95%) — dark cloud, heavy rain, lightning

    /// Steady-state weather for a mood. `.celebrating` maps to steady `.sunny` because the burst of
    /// confetti is a transient `WeatherEvent`, not a standing condition — the backdrop while
    /// celebrating is simply bright.
    public static func from(_ emotion: MascotEmotion) -> WeatherCondition {
        switch emotion {
        case .sleeping:    return .clearSky
        case .celebrating: return .sunny
        case .happy:       return .sunny
        case .neutral:     return .cloudy
        case .worried:     return .storm
        case .alarmed:     return .heavyStorm
        }
    }
}

/// A one-shot weather moment, fired on a usage transition (see `MetricsStore.pendingWeatherEvents`).
/// Each fires exactly once per transition and is consumed by the view — never stored as steady state.
public enum WeatherEvent: Sendable, Equatable {
    case confetti         // a fresh 5-hour window just started
    case lightningStrike  // pressure just crossed into `.alarmed` (≥95/100%)
}
