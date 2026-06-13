import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct FiveHourBlockTests {
    let pricing = PricingTable.default
    let hour: TimeInterval = 3600
    private var base: Date { Date(timeIntervalSince1970: 1_779_998_400) }   // hour-aligned

    private func entries(_ offsetsHours: [Double]) -> [UsageEntry] {
        offsetsHours.map { TestSupport.entry(at: base.addingTimeInterval($0 * hour), input: 100, output: 10) }
    }

    @Test func activeSessionStartsAtFirstMessage() {
        let s = FiveHourBlockEngine.activeSession(from: entries([0]), pricing: pricing,
                                                  now: base.addingTimeInterval(2 * hour))
        let b = try! #require(s)
        #expect(b.start == base)                       // not hour-floored, not advanced
        #expect(b.endsAt == base.addingTimeInterval(5 * hour))
        #expect(b.workTokens == 110)
    }

    @Test func gridAdvancesToBoundaryNotFirstMessageInSlot() {
        // Continuous activity (gaps < 5h): anchor stays at base, grid advances by 5h.
        // The current slot starts at base+5h even though the only message in it is at +6h.
        let s = FiveHourBlockEngine.activeSession(from: entries([0, 3, 6]), pricing: pricing,
                                                  now: base.addingTimeInterval(7 * hour))
        let b = try! #require(s)
        #expect(b.start == base.addingTimeInterval(5 * hour))     // grid boundary, not 6h
        #expect(b.actualStart == base.addingTimeInterval(6 * hour))
        #expect(b.workTokens == 110)                              // only the +6h entry
    }

    @Test func gapOverFiveHoursResetsAnchor() {
        // 6h gap → anchor resets to the +6h message; session = [6h, 11h).
        let s = FiveHourBlockEngine.activeSession(from: entries([0, 6]), pricing: pricing,
                                                  now: base.addingTimeInterval(7 * hour))
        let b = try! #require(s)
        #expect(b.start == base.addingTimeInterval(6 * hour))
        #expect(b.workTokens == 110)
    }

    @Test func idleSessionReturnsNil() {
        // Last activity 6h before now → session expired.
        let s = FiveHourBlockEngine.activeSession(from: entries([0]), pricing: pricing,
                                                  now: base.addingTimeInterval(6 * hour))
        #expect(s == nil)
    }

    /// Audit: when the grid steps to a new 5h window, the count RESETS — only entries in
    /// the new window are summed; the prior window's tokens drop off.
    @Test func tokensResetWhenSessionGridAdvances() {
        // Continuous activity at 0h..4h (window #1), then one entry at +5h (window #2 start).
        let es = entries([0, 2, 4, 5])
        // Late in window #1: sums the three early entries.
        let w1 = FiveHourBlockEngine.activeSession(from: es, pricing: pricing,
                                                   now: base.addingTimeInterval(4.5 * hour))!
        #expect(w1.start == base)
        #expect(w1.workTokens == 330)                 // 0h,2h,4h
        // Into window #2: count resets to just the +5h entry.
        let w2 = FiveHourBlockEngine.activeSession(from: es, pricing: pricing,
                                                   now: base.addingTimeInterval(5.5 * hour))!
        #expect(w2.start == base.addingTimeInterval(5 * hour))
        #expect(w2.workTokens == 110)                 // only +5h — the prior window reset off
    }

    /// The bug the user hit: the 5h window rolls over while idle (but < 5h since the last
    /// use, so the session hasn't fully expired). The new window must read ZERO — the old
    /// tokens drop off on the clock, without needing a new message to trigger it.
    @Test func windowRollsToZeroWhenIdleAcrossBoundary() {
        let es = entries([0, 2])                       // last activity at +2h
        let s = FiveHourBlockEngine.activeSession(from: es, pricing: pricing,
                                                  now: base.addingTimeInterval(5.5 * hour))
        let b = try! #require(s)                        // not nil: only 3.5h idle (< 5h)
        #expect(b.start == base.addingTimeInterval(5 * hour))   // advanced to window #2
        #expect(b.workTokens == 0)                              // reset — no entries in the new window
        #expect(b.endsAt == base.addingTimeInterval(10 * hour))
    }

    @Test func concurrentSessionsShareWindow() {
        let a = TestSupport.entry(id: "a", at: base.addingTimeInterval(60), input: 10, output: 0)
        let b = TestSupport.entry(id: "b", at: base.addingTimeInterval(120), input: 20, output: 0, sidechain: true)
        let s = FiveHourBlockEngine.activeSession(from: [a, b], pricing: pricing,
                                                  now: base.addingTimeInterval(hour))
        #expect(s?.workTokens == 30)
    }
}
