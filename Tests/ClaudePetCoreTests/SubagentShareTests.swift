import Testing
import Foundation
@testable import ClaudePetCore

/// `daySidechainShare` and the weekday label the two weekly charts share.
///
/// The share drives a bar HEIGHT against a full-height track, which is why it is clamped where the
/// other two `sidechainShare` overloads aren't — those feed a tooltip clause, where an impossible
/// figure reads as odd rather than drawing outside its own slot.
@MainActor
@Suite struct SubagentShareTests {

    private func freshStore() -> MetricsStore {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return TestSupport.store(defaults: d)
    }

    /// Fixed Gregorian calendar. `Calendar.current` on this machine is the **Buddhist** calendar
    /// (today's year is 2569), which has already made a test in this repo assert nothing at all.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func day(work: Int, total: Int, sidechainWork: Int, sidechainTotal: Int) -> DayTotal {
        DayTotal(date: at(2026, 7, 14), workTokens: work, totalTokens: total, costUSD: 1,
                 sidechainWorkTokens: sidechainWork, sidechainTotalTokens: sidechainTotal)
    }

    // MARK: - daySidechainShare

    /// The basis is the point, not a detail: subagent turns are a big slice of *work* and a small
    /// slice of cache-inclusive *total*, because a subagent runs in a short-lived context while the
    /// main conversation re-reads a large cached one every turn. The chart's caption names which.
    @Test func theShareFollowsTheTokenBasis() {
        let store = freshStore()
        let d = day(work: 1000, total: 10_000, sidechainWork: 150, sidechainTotal: 800)

        store.tokenBasis = .work
        #expect(abs(store.daySidechainShare(d) - 0.15) < 1e-9)
        store.tokenBasis = .total
        #expect(abs(store.daySidechainShare(d) - 0.08) < 1e-9)
    }

    /// A day with nothing in it must be 0, not NaN — it is multiplied by a bar area.
    @Test func anEmptyDayIsZeroAndNotNaN() {
        let store = freshStore()
        let d = day(work: 0, total: 0, sidechainWork: 0, sidechainTotal: 0)
        for basis in [TokenBasis.work, .total] {
            store.tokenBasis = basis
            let s = store.daySidechainShare(d)
            #expect(s == 0)
            #expect(!s.isNaN)
        }
    }

    /// A day that ran turns but delegated none of them is 0% — distinct from "no usage", which the
    /// chart prints as "–". Both are real states and they must not collapse into each other.
    @Test func aDayWithoutSubagentsIsZeroWhileStillHavingTokens() {
        let store = freshStore()
        let d = day(work: 500, total: 9_000, sidechainWork: 0, sidechainTotal: 0)
        #expect(store.daySidechainShare(d) == 0)
        #expect(store.dayTokens(d) > 0)
    }

    /// An all-subagent day is exactly 1, and anything beyond it clamps rather than drawing outside
    /// its slot. The slice is a subset of the day by construction, so this should never bind.
    @Test func theShareIsClampedToOne() {
        let store = freshStore()
        store.tokenBasis = .work
        #expect(store.daySidechainShare(day(work: 400, total: 400,
                                            sidechainWork: 400, sidechainTotal: 400)) == 1)
        #expect(store.daySidechainShare(day(work: 400, total: 400,
                                            sidechainWork: 999, sidechainTotal: 999)) == 1)
    }

    // MARK: - Format.weekdayLabel

    /// Both ambiguous pairs get two letters: S/S and T/T. English initials are S M T W T F S, so
    /// fixing only the weekend left Tuesday and Thursday indistinguishable — and these slots begin on
    /// the weekly *reset* day, which moves, so position can't separate them the way it does in the
    /// billing calendar's fixed Sunday-first column.
    @Test func bothAmbiguousPairsGetTwoLetters() {
        // 2026-07-11 Sat, 07-12 Sun, 07-14 Tue, 07-16 Thu.
        #expect(cal.component(.weekday, from: at(2026, 7, 11)) == 7)
        #expect(cal.component(.weekday, from: at(2026, 7, 12)) == 1)
        #expect(cal.component(.weekday, from: at(2026, 7, 14)) == 3)
        #expect(cal.component(.weekday, from: at(2026, 7, 16)) == 5)
        #expect(Format.weekdayLabel(for: at(2026, 7, 11), calendar: cal) == "Sa")
        #expect(Format.weekdayLabel(for: at(2026, 7, 12), calendar: cal) == "Su")
        #expect(Format.weekdayLabel(for: at(2026, 7, 14), calendar: cal) == "Tu")
        #expect(Format.weekdayLabel(for: at(2026, 7, 16), calendar: cal) == "Th")
    }

    /// The unambiguous three stay single — a label is a hint, and short ones scan faster.
    @Test func mondayWednesdayAndFridayStaySingleLetters() {
        for d in [13, 15, 17] {     // Mon, Wed, Fri
            let label = Format.weekdayLabel(for: at(2026, 7, d), calendar: cal)
            #expect(label.count == 1, "expected one letter for 2026-07-\(d), got \(label)")
        }
    }

    /// **Seven slots, seven distinct labels, wherever the week opens.** This is the property the
    /// two-letter rule exists for, and it now actually holds — it asserted six for one release,
    /// because Tuesday and Thursday both read "T" and the collision was documented rather than fixed.
    ///
    /// Every rotation is checked, not just the current reset day: the whole reason position can't be
    /// relied on here is that the opening day moves.
    @Test func everyWeekdayIsDistinctWhereverTheWeekOpens() {
        for offset in 0..<7 {
            let start = cal.date(byAdding: .day, value: offset, to: at(2026, 7, 13))!
            let labels = (0..<7).map {
                Format.weekdayLabel(for: cal.date(byAdding: .day, value: $0, to: start)!, calendar: cal)
            }
            #expect(Set(labels).count == 7, "starting \(start): \(labels)")
            #expect(Set(labels) == ["M", "Tu", "W", "Th", "F", "Sa", "Su"], "\(labels)")
        }
    }
}
