import Foundation

/// The pet's ambient sky, derived from its mood (see `MetricsStore.weatherCondition`). The mascot's
/// face and its weather share one source of truth — `MascotEmotion`, and therefore the **5-hour
/// session** — so they can never disagree: calm sun when idle, sun while there's headroom, clouds at
/// mid-usage, rain/storm near a limit, and a heavy storm with lightning past it.
///
/// The weekly limit deliberately does **not** appear here. Driving the sky from weekly while the face
/// followed the session would let one image contradict itself — a grinning pet under a black cloud,
/// with nothing on screen to explain why. Weekly is the ground under the pet's feet instead
/// (`GroundCondition`), which is a separate layer and can never collide with this one.
public enum WeatherCondition: String, CaseIterable, Sendable {
    case clearSky      // idle / sleeping — calm, a gentle sun
    case sunny         // plenty of headroom (celebrating / happy)
    case partlyCloudy  // easing off the top (content) — sun with one cloud crossing it
    case cloudy        // mid usage (neutral) — a few drifting clouds
    case overcast      // working hard (focused) — full cloud cover, no sun, no rain yet
    case drizzle       // getting close (worried) — light, thin rain
    case storm         // at the edge (alarmed) — dark cloud, real rain
    case heavyStorm    // past the limit (exhausted) — heavy rain and lightning

    /// Steady-state weather for a mood. `.celebrating` maps to steady `.sunny` because the burst of
    /// confetti is a transient `WeatherEvent`, not a standing condition — the backdrop while
    /// celebrating is simply bright.
    public static func from(_ emotion: MascotEmotion) -> WeatherCondition {
        switch emotion {
        case .sleeping:    return .clearSky
        case .celebrating: return .sunny
        case .happy:       return .sunny
        case .content:     return .partlyCloudy
        case .neutral:     return .cloudy
        case .focused:     return .overcast
        case .worried:     return .drizzle
        case .alarmed:     return .storm
        case .exhausted:   return .heavyStorm
        }
    }
}

/// A one-shot weather moment, fired on a usage transition (see `MetricsStore.pendingWeatherEvents`).
/// Each fires exactly once per transition and is consumed by the view — never stored as steady state.
public enum WeatherEvent: Sendable, Equatable {
    case confetti         // a fresh 5-hour window just started
    case lightningStrike  // pressure just crossed into `.alarmed` (≥95/100%)
}
