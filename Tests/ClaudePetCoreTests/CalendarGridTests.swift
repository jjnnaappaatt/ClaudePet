import Testing
import Foundation
@testable import ClaudePetCore

/// The calendar grid is the one part of the billing-cycle calendar that can be wrong invisibly — a day
/// dropped, duplicated, or sitting under the wrong weekday still *looks* like a calendar.
///
/// Every test passes an explicit calendar. `Calendar.current` on this machine is the Buddhist calendar
/// (today's year reads 2569), and while weekday numbering is era-independent, `firstWeekday` is locale
/// data and would make these results depend on the host.
@Suite struct CalendarGridTests {

    private func cal(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = firstWeekday
        return c
    }

    /// 2026-07-04 is a Saturday. Consecutive days from there.
    private func days(from y: Int, _ m: Int, _ d: Int, count: Int, calendar: Calendar) -> [DayTotal] {
        let start = calendar.date(from: DateComponents(year: y, month: m, day: d))!
        return (0..<count).map {
            DayTotal(date: calendar.date(byAdding: .day, value: $0, to: start)!,
                     workTokens: $0, totalTokens: $0, costUSD: Double($0))
        }
    }

    // MARK: - Padding

    @Test func aCycleStartingMidWeekIsPaddedToItsWeekdayColumn() {
        let c = cal(firstWeekday: 2)                       // Monday-first
        let grid = CalendarGrid.weeks(days(from: 2026, 7, 4, count: 31, calendar: c), calendar: c)
        // 4 Jul 2026 is a Saturday → 5 blanks before it on a Monday-first grid.
        #expect(grid[0].prefix(5).allSatisfy { $0 == nil })
        #expect(grid[0][5] != nil)
        #expect(c.component(.weekday, from: grid[0][5]!.date) == 7)   // Saturday
    }

    @Test func theSameCycleShiftsColumnOnASundayFirstLocale() {
        let c = cal(firstWeekday: 1)                       // Sunday-first
        let grid = CalendarGrid.weeks(days(from: 2026, 7, 4, count: 31, calendar: c), calendar: c)
        // Saturday is the LAST column when the week starts on Sunday.
        #expect(grid[0].prefix(6).allSatisfy { $0 == nil })
        #expect(grid[0][6] != nil)
    }

    @Test func aCycleStartingOnTheFirstWeekdayNeedsNoLeadingBlanks() {
        let c = cal(firstWeekday: 2)
        // 2026-07-06 is a Monday.
        let grid = CalendarGrid.weeks(days(from: 2026, 7, 6, count: 14, calendar: c), calendar: c)
        #expect(grid[0][0] != nil)
        #expect(grid.count == 2)
        #expect(grid.allSatisfy { $0.allSatisfy { $0 != nil } })      // exactly two full weeks
    }

    // MARK: - Nothing lost, nothing invented

    @Test func everyDayAppearsExactlyOnceAndRowsAreAlwaysSeven() {
        let c = cal(firstWeekday: 2)
        for count in [1, 6, 7, 8, 28, 29, 30, 31, 32] {
            let input = days(from: 2026, 7, 4, count: count, calendar: c)
            let grid = CalendarGrid.weeks(input, calendar: c)
            #expect(grid.allSatisfy { $0.count == 7 })
            let out = grid.flatMap { $0 }.compactMap { $0 }
            #expect(out.count == count)
            #expect(out.map(\.date) == input.map(\.date))            // order preserved, none duplicated
        }
    }

    @Test func daysLandUnderTheWeekdayColumnTheyBelongTo() {
        let c = cal(firstWeekday: 2)
        let grid = CalendarGrid.weeks(days(from: 2026, 7, 4, count: 31, calendar: c), calendar: c)
        let order = CalendarGrid.weekdayOrder(calendar: c)
        for row in grid {
            for (col, day) in row.enumerated() {
                guard let day else { continue }
                #expect(c.component(.weekday, from: day.date) == order[col])
            }
        }
    }

    @Test func emptyInputYieldsNoRowsRatherThanARowOfBlanks() {
        #expect(CalendarGrid.weeks([], calendar: cal(firstWeekday: 2)).isEmpty)
    }

    @Test func weekdayOrderStartsAtTheLocalesFirstWeekday() {
        #expect(CalendarGrid.weekdayOrder(calendar: cal(firstWeekday: 2)) == [2, 3, 4, 5, 6, 7, 1])
        #expect(CalendarGrid.weekdayOrder(calendar: cal(firstWeekday: 1)) == [1, 2, 3, 4, 5, 6, 7])
        #expect(CalendarGrid.weekdayOrder(calendar: cal(firstWeekday: 7)) == [7, 1, 2, 3, 4, 5, 6])
    }
}
