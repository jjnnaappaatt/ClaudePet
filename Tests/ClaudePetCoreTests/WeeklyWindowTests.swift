import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct WeeklyWindowTests {
    let pricing = PricingTable.default
    let day: TimeInterval = 86_400
    private var anchor: Date { Date(timeIntervalSince1970: 1_704_067_200) }   // 2024-01-01 Mon

    private func entry(_ daysFromAnchor: Double, work: Int = 100) -> UsageEntry {
        TestSupport.entry(at: anchor.addingTimeInterval(daysFromAnchor * day), input: work, output: 0)
    }

    @Test func windowContainsNowAndIsSevenDays() {
        let now = anchor.addingTimeInterval(10 * day)        // 3 days into week #2
        let w = WeeklyWindowEngine.window(anchor: anchor, now: now)
        #expect(w.start == anchor.addingTimeInterval(7 * day))
        #expect(w.end == anchor.addingTimeInterval(14 * day))
        #expect(now >= w.start && now < w.end)
    }

    @Test func onlyCountsEntriesInsideTheActiveWindow() {
        let now = anchor.addingTimeInterval(8 * day)         // window [7d, 14d)
        let entries = [
            entry(2, work: 500),   // week #1 — excluded (reset off)
            entry(6.9, work: 999), // week #1, just before reset — excluded
            entry(7.0, work: 100), // exactly at reset boundary — included
            entry(8.0, work: 50),  // inside — included
        ]
        let w = WeeklyWindowEngine.current(from: entries, pricing: pricing, anchor: anchor, now: now)
        #expect(w.workTokens == 150)                          // 100 + 50 only
    }

    /// The audit the user asked for: crossing a weekly boundary RESETS the total to zero.
    @Test func totalResetsToZeroAtBoundary() {
        let entries = [entry(2, work: 800), entry(5, work: 700)]   // all in week #1
        // Just before reset: full total visible.
        let before = WeeklyWindowEngine.current(from: entries, pricing: pricing,
                                                anchor: anchor, now: anchor.addingTimeInterval(7 * day - 1))
        #expect(before.workTokens == 1500)
        // One second after reset (no new activity): back to zero.
        let after = WeeklyWindowEngine.current(from: entries, pricing: pricing,
                                               anchor: anchor, now: anchor.addingTimeInterval(7 * day + 1))
        #expect(after.workTokens == 0)
        #expect(after.start == anchor.addingTimeInterval(7 * day))
        #expect(after.resetsIn(now: anchor.addingTimeInterval(7 * day + 1)) == 7 * day - 1)
    }

    @Test func resetsInCountsDownToTheBoundary() {
        let now = anchor.addingTimeInterval(7 * day - 3600)   // 1h before week #1 ends
        let w = WeeklyWindowEngine.current(from: [], pricing: pricing, anchor: anchor, now: now)
        #expect(w.resetsIn(now: now) == 3600)
    }

    // No-DST zone so a fixed 7-day grid keeps every boundary on the same wall-clock time.
    private var bangkok: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        return c
    }

    @Test func anchorLandsOnConfiguredWeekdayAndTime() {
        let a = WeeklyWindowEngine.anchor(weekday: 2, hour: 15, minute: 0, calendar: bangkok)  // Monday 3 PM
        let c = bangkok.dateComponents([.weekday, .hour, .minute], from: a)
        #expect(c.weekday == 2)   // Monday
        #expect(c.hour == 15)     // 3 PM
        #expect(c.minute == 0)
    }

    @Test func weeklyGridResetsOnTheConfiguredWeekdayAndTime() {
        let cal = bangkok
        let a = WeeklyWindowEngine.anchor(weekday: 2, hour: 15, minute: 0, calendar: cal)
        let now = a.addingTimeInterval(100 * day + 12_345)   // arbitrary, weeks later
        let w = WeeklyWindowEngine.window(anchor: a, now: now)
        let end = cal.dateComponents([.weekday, .hour, .minute], from: w.end)
        #expect(end.weekday == 2 && end.hour == 15 && end.minute == 0)   // still Monday 3 PM
        #expect(now >= w.start && now < w.end)
    }

    @Test func countdownShowsHoursAndMinutesUnderOneDay() {
        #expect(Format.durationLong(25 * 3600) == "1d 1h")              // ≥ 1 day → days + hours
        #expect(Format.durationLong(23 * 3600 + 12 * 60) == "23h 12m")  // < 1 day → hours + minutes
        #expect(Format.durationLong(45 * 60) == "45m")                  // < 1 hour → minutes
    }
}
