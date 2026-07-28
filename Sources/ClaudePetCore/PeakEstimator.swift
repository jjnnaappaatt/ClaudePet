import Foundation

/// Picks the "how hard do I usually push" anchor out of a set of completed usage windows.
/// The auto-budget denominator is this value × `(1 + peakHeadroom)`.
///
/// **Deliberately not `max`.** The two grids that feed this accumulate completed windows at
/// wildly different rates — one 5h cell per working session versus one cell per week — so on
/// real data the 5h pool was 137 windows against the weekly pool's 9. `max` over n samples
/// climbs with n and never converges, so the 5h denominator sat deep in its own tail (its top
/// window was 1.5× the next-heaviest and 7× the median) while the weekly denominator sat right
/// beside a typical heavy week (1.05× the next-heaviest). The same "% of my own record" ended
/// up meaning two different things on the two gauges — a heavy session read 42% while a heavy
/// week read 79% — and the gap widened every week as more blocks piled up.
///
/// A fixed quantile converges instead, so both grids land at the same strictness no matter how
/// many windows each has accumulated, and one exceptional session stops pinning the denominator
/// for good. Below 21 windows it degrades to `max`, which is the only sensible answer when
/// there's barely any history.
enum PeakEstimator {

    /// Share of completed windows allowed to sit *above* the anchor.
    static let tailFraction = 0.05

    /// Index into a descending sort. `ceil(n × tailFraction)` windows may exceed the anchor,
    /// floored at 1 so a short history still yields the heaviest window rather than nothing.
    static func rank(forCount n: Int) -> Int {
        guard n > 0 else { return 0 }
        let k = max(1, Int((Double(n) * tailFraction).rounded(.up)))
        return min(k, n) - 1
    }

    static func anchor(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.sorted(by: >)[rank(forCount: values.count)]
    }

    static func anchor(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted(by: >)[rank(forCount: values.count)]
    }
}
