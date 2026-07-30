import Foundation

/// Lays a run of consecutive days out as calendar weeks — rows are weeks, columns weekdays.
///
/// A billing cycle starts on the subscription's anniversary date, which lands on an arbitrary weekday,
/// so the first week needs leading blanks and the last needs trailing ones. Kept out of the view and in
/// Core because it is the only part of the calendar with logic that can be wrong in a way a screenshot
/// wouldn't show: a day silently dropped, duplicated, or placed under the wrong weekday.
public enum CalendarGrid {

    /// `days` must be consecutive calendar dates, oldest first — which is exactly what
    /// `Aggregates.cycleDaily` produces.
    ///
    /// Column order follows `calendar.firstWeekday`, so a Sunday-start locale gets Sunday first without
    /// the caller doing anything. Returns `[]` for no input rather than a row of blanks.
    public static func weeks(_ days: [DayTotal], calendar: Calendar = .current) -> [[DayTotal?]] {
        guard let first = days.first else { return [] }

        // 0 = the grid's leftmost column. `weekday` is 1...7 with 1 = Sunday, and `firstWeekday` uses
        // the same numbering, so the offset is their difference wrapped into 0..<7.
        let weekday = calendar.component(.weekday, from: first.date)
        let lead = ((weekday - calendar.firstWeekday) % 7 + 7) % 7

        var cells: [DayTotal?] = Array(repeating: nil, count: lead)
        cells.append(contentsOf: days.map { Optional($0) })
        // Complete the final week so every row has 7 columns and the grid stays rectangular.
        if cells.count % 7 != 0 {
            cells.append(contentsOf: Array(repeating: nil, count: 7 - cells.count % 7))
        }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0 ..< $0 + 7]) }
    }

    /// The weekday symbols in the same column order as `weeks`, for the header row.
    public static func weekdayOrder(calendar: Calendar = .current) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }
}
