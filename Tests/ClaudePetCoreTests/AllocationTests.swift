import Testing
import Foundation
@testable import ClaudePetCore

/// Allocation behaviour that no other test can see fail.
///
/// The changes these guard produce **identical output** to the code they replaced — that is the
/// point of them. So every functional test in the suite passes either way, and a regression here is
/// invisible except through memory: `recompute()` runs on a 30s idle timer, and re-sorting the
/// already-sorted entry list allocated two fresh ~16 MB buffers each time. Nothing reclaimed them in
/// between, because `malloc_zone_pressure_relief` runs only after a *scan*, deliberately. `vmmap`
/// showed the residue as empty `MALLOC_LARGE` regions of exactly 15.6 MB — `128,101 × 128 bytes`.
@Suite struct AllocationTests {

    let pricing = PricingTable.default

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Entries spread over several 5h blocks and a >=5h gap, so both engines have real structure to
    /// get wrong — not a single block where any ordering gives the same answer.
    private func fixture() -> [UsageEntry] {
        var e: [UsageEntry] = []
        for (i, hours) in [0, 1, 3, 6, 7, 12, 30, 31, 33, 50].enumerated() {
            e.append(TestSupport.entry(id: "m\(i)",
                                       at: at(2026, 7, 10).addingTimeInterval(Double(hours) * 3600),
                                       input: 100 * (i + 1), output: 10 * (i + 1),
                                       sidechain: i % 3 == 0))
        }
        return e
    }

    /// A deterministic scramble — `shuffled()` would make a failure unreproducible.
    private func scrambled(_ e: [UsageEntry]) -> [UsageEntry] {
        var out = e
        out.reverse()
        out.swapAt(0, 4)
        out.swapAt(2, 7)
        return out
    }

    // MARK: - Correctness: order must not change any answer

    @Test func unsortedEntriesGiveTheSameSessionAsSortedOnes() {
        let now = at(2026, 7, 12, 14)
        let sorted = fixture()
        let a = FiveHourBlockEngine.activeSession(from: sorted, pricing: pricing, now: now)
        let b = FiveHourBlockEngine.activeSession(from: scrambled(sorted), pricing: pricing, now: now)
        #expect(a == b)
        #expect(a != nil)                 // else the test proves nothing
        #expect((a?.workTokens ?? 0) > 0)
    }

    @Test func unsortedEntriesGiveTheSamePeakAsSortedOnes() {
        let now = at(2026, 7, 12, 14)
        let sorted = fixture()
        let a = FiveHourBlockEngine.peakCompleted(from: sorted, pricing: pricing, now: now)
        let b = FiveHourBlockEngine.peakCompleted(from: scrambled(sorted), pricing: pricing, now: now)
        #expect(a.work == b.work)
        #expect(abs(a.weighted - b.weighted) < 1e-9)
        #expect(abs(a.cost - b.cost) < 1e-9)
        #expect(a.work > 0)
    }

    // MARK: - The allocation guarantee itself

    /// **The one test that can see the regression.** Compares the buffer's base address before and
    /// after: already-ordered input must come back as the *same storage*, not a copy. Reinstating a
    /// plain `.sorted` keeps every other test in this file green and fails only this one.
    @Test func alreadySortedEntriesAreNotCopied() {
        let sorted = fixture()
        let before = sorted.withUnsafeBufferPointer { $0.baseAddress }
        let after = FiveHourBlockEngine.timeOrdered(sorted).withUnsafeBufferPointer { $0.baseAddress }
        #expect(before == after)

        // …and unsorted input must still be re-sorted, i.e. a genuinely different buffer.
        let messy = scrambled(sorted)
        let messyBefore = messy.withUnsafeBufferPointer { $0.baseAddress }
        let reordered = FiveHourBlockEngine.timeOrdered(messy)
        #expect(reordered.withUnsafeBufferPointer { $0.baseAddress } != messyBefore)
        #expect(reordered.map(\.timestamp) == sorted.map(\.timestamp))
    }

    /// `UsageScanner.merge` sorts what the caller hands it, and its comment has always claimed that
    /// sort is in place. It wasn't: a plain parameter is *borrowed*, so the caller's array stayed
    /// live, `var sorted = entries` left the buffer non-uniquely referenced, and `sort()` took a full
    /// copy-on-write copy. On the real corpus that is a second ~15.7 MB buffer allocated and freed on
    /// **every scan**, and FSEvents rescans on every transcript write.
    ///
    /// The array has to be built inside a closure so it is a genuine temporary at the call — a local
    /// `let` would still be live and would copy no matter what the parameter says, which is exactly
    /// the trap that made the original comment wrong.
    @Test func mergeSortsInPlaceWithoutCopying() {
        var built: UnsafeRawPointer?
        let merged = UsageScanner.merge({
            let a = scrambled(fixture())
            built = a.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
            return a
        }(), deduplicated: false)
        let out = merged.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        #expect(out == built)
        #expect(merged.map(\.timestamp) == fixture().map(\.timestamp))   // and it really did sort
    }

    /// Edge cases the O(n) scan has to survive — both callers guard `!entries.isEmpty`, but the
    /// helper must not depend on that.
    @Test func timeOrderedHandlesEmptyAndSingleAndEqualTimestamps() {
        #expect(FiveHourBlockEngine.timeOrdered([]).isEmpty)
        let one = [TestSupport.entry(at: at(2026, 7, 10), input: 1, output: 0)]
        #expect(FiveHourBlockEngine.timeOrdered(one).count == 1)
        // Equal timestamps are ordered (not strictly ascending) — must not trigger a re-sort.
        let ties = (0..<4).map { TestSupport.entry(id: "t\($0)", at: at(2026, 7, 10), input: 1, output: 0) }
        let tiesBefore = ties.withUnsafeBufferPointer { $0.baseAddress }
        #expect(FiveHourBlockEngine.timeOrdered(ties).withUnsafeBufferPointer { $0.baseAddress }
                == tiesBefore)
    }
}
