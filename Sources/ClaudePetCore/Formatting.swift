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

    /// $0.06, $4.21, $402, $1,001, $12.5k
    ///
    /// Abbreviation starts at $10k, not $1k. At the old threshold `$1,001` printed as "$1k" — three
    /// digits discarded from a number that fits perfectly well in full, and the headline sat unchanged
    /// at "$1k" for days while the real figure climbed. Above $10k the abbreviation earns its keep.
    public static func currency(_ usd: Double) -> String {
        if usd >= 10_000 { return "$" + trim(usd / 1000) + "k" }
        if usd >= 1000 { return "$" + grouped(usd) }
        if usd >= 100 { return "$" + String(format: "%.0f", usd) }
        return "$" + String(format: "%.2f", usd)
    }

    /// 1001 -> "1,001", using the user's own grouping separator.
    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// Thousands-separated whole numbers: `125,137`. Public because the KPI tiles print raw counts
    /// (sessions, messages) that must not be abbreviated the way token figures are — "125k messages"
    /// loses the precision that makes the number worth showing.
    public static func grouped(_ v: Double) -> String {
        grouping.string(from: NSNumber(value: v.rounded())) ?? String(format: "%.0f", v)
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
    /// An hour as a word: `9am`, `2pm`, `12am`.
    ///
    /// Deliberately a different convention from the hour chart's own axis, which runs 0…24. They
    /// answer different questions: the axis is a *scale*, read by position, where 0…24 maps
    /// one-to-one onto the twenty-four buckets; this is a *single time*, read as a word, where "9am"
    /// lands without the reader counting gridlines. Not an oversight — don't "fix" one to match the
    /// other without deciding which reading you're serving.
    public static func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        return "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "am" : "pm")"
    }

    /// The weekday label under a weekly chart's slot: one letter where that is unambiguous, **two
    /// where it is not** — `Su Mo→M Tu W Th F Sa`, i.e. `M Tu W Th F Sa Su`.
    ///
    /// English initials are S M T W T F S: **two pairs collide, not one.** Unlike the billing
    /// calendar — where Sunday is always the first column, so position disambiguates — these slots
    /// begin on the weekly *reset* day. That day moves, so the order rotates and neither the two S's
    /// nor the two T's can be told apart by where they sit.
    ///
    /// The weekend pair was fixed first and the weekday pair left alone, on the grounds that widening
    /// the axis wasn't worth it. That was the wrong call for the same reason the first fix was the
    /// right one: a reader who can't tell Tuesday from Thursday can't read the chart. Two letters
    /// costs ~4pt of a ~34pt slot.
    ///
    /// Still only the ambiguous days — M, W and F stay single, because a label is a hint and the
    /// short ones are quicker to scan. Shared by both weekly charts so they can't diverge.
    public static func weekdayLabel(for date: Date, calendar: Calendar = .current) -> String {
        twoLetter(calendar.component(.weekday, from: date)) ?? weekdayInitial.string(from: date)
    }

    /// The same label from a weekday *number*, for a grid whose columns are weekdays rather than
    /// dates — the billing calendar. It has its own fixed Sunday-first order, so position alone would
    /// disambiguate there; it shares this anyway because the calendar sits beside both weekly charts
    /// on one screen, and "T" in one place and "Tu" in another two cards away is its own small lie.
    public static func weekdayLabel(weekday: Int, calendar: Calendar = .current) -> String {
        if let short = twoLetter(weekday) { return short }
        // Build a real date with that weekday so the initial comes from the locale, not a hardcoded
        // list — the same trick the calendar used before this moved here.
        var comps = DateComponents()
        comps.weekday = weekday
        guard let d = calendar.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime)
        else { return "" }
        return weekdayInitial.string(from: d)
    }

    /// Two letters for the days a single initial can't separate; nil for the ones it can.
    private static func twoLetter(_ weekday: Int) -> String? {
        switch weekday {
        case 1:  "Su"
        case 3:  "Tu"
        case 5:  "Th"
        case 7:  "Sa"
        default: nil
        }
    }

    private static let weekdayInitial: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f
    }()

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
