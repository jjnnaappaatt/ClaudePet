import Foundation

/// Compact, glanceable formatting for the widget. Pure + testable.
public enum Format {
    /// 932 -> "932", 12_400 -> "12.4k", 41_200_000 -> "41.2M", 3_100_000_000 -> "3.1B"
    public static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch abs(n) {
        case 1_000_000_000...: return trim(v / 1_000_000_000) + "B"
        case 1_000_000...:     return trim(v / 1_000_000) + "M"
        case 1_000...:         return trim(v / 1_000) + "k"
        default:               return "\(n)"
        }
    }

    /// $0.06, $4.21, $402, $1.2k
    public static func currency(_ usd: Double) -> String {
        if usd >= 1000 { return "$" + trim(usd / 1000) + "k" }
        if usd >= 100 { return "$" + String(format: "%.0f", usd) }
        return "$" + String(format: "%.2f", usd)
    }

    /// 0 -> "0m", 6720 -> "1h 52m"
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Days-aware for multi-day countdowns: 0 -> "0m", 90_000 -> "1d 1h", 6720 -> "1h 52m"
    public static func durationLong(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Friendly 12-hour clock label: 0 -> "12a", 9 -> "9a", 12 -> "12p", 18 -> "6p", 23 -> "11p"
    public static func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let ampm = h < 12 ? "a" : "p"
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve)\(ampm)"
    }

    /// Compact "time since": "just now", "5m ago", "2h ago", "3d ago".
    public static func relativeAge(from date: Date, now: Date = Date()) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        switch s {
        case ..<60:     return "just now"
        case ..<3600:   return "\(s / 60)m ago"
        case ..<86_400: return "\(s / 3600)h ago"
        default:        return "\(s / 86_400)d ago"
        }
    }

    /// Drops a trailing ".0": 41.0 -> "41", 41.2 -> "41.2"
    private static func trim(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }
}
