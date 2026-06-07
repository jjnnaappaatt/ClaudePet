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

    /// Drops a trailing ".0": 41.0 -> "41", 41.2 -> "41.2"
    private static func trim(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }
}
