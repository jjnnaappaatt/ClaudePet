import Testing
import Foundation
@testable import ClaudePetCore

/// Sub-agent (sidechain) turns are counted — they always were — but their cost is almost entirely
/// cache reads, so on the WORK basis they look like they aren't. These cover the split that lets
/// the UI say so out loud.
@MainActor
@Suite struct SidechainSplitTests {

    let pricing = PricingTable.default
    let cal = Calendar.current

    private var noon: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 7; c.hour = 12; c.minute = 0
        return cal.date(from: c)!
    }

    private func freshStore() -> MetricsStore {
        let name = "sidechain-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return MetricsStore(defaults: d)
    }

    /// A main turn and a sub-agent turn with the same total size but very different work sizes —
    /// the real shape of sub-agent usage (tiny prompt, huge cache read).
    private func pair(at now: Date) -> [UsageEntry] {
        [
            TestSupport.entry(id: "m", at: now, input: 100, output: 0, cacheRead: 900),
            TestSupport.entry(id: "s", at: now, input: 40, output: 0, cacheRead: 960, sidechain: true),
        ]
    }

    @Test func totalsSplitTracksSidechainEntries() {
        let agg = Aggregator.compute(entries: pair(at: noon), pricing: pricing,
                                     now: noon, calendar: cal)
        #expect(agg.today.workTokens == 140)
        #expect(agg.today.totalTokens == 2000)
        #expect(agg.today.sidechainWorkTokens == 40)
        #expect(agg.today.sidechainTotalTokens == 1000)
    }

    /// The whole point: the same sub-agent turn is 29% of the figure on the work basis and 50% on
    /// the total basis. Under "work" it reads as a rounding error; under "total" it's half.
    @Test func sidechainShareDependsOnTheBasis() {
        let store = freshStore()
        store.ingestForTesting(pair(at: Date()))

        store.tokenBasis = .work
        #expect(store.sidechainTokens(store.today) == 40)
        #expect(abs(store.sidechainShare(store.today) - 40.0 / 140.0) < 0.0001)

        store.tokenBasis = .total
        #expect(store.sidechainTokens(store.today) == 1000)
        #expect(abs(store.sidechainShare(store.today) - 0.5) < 0.0001)
    }

    @Test func splitIsZeroWhenSubagentsExcluded() {
        let store = freshStore()
        store.ingestForTesting(pair(at: Date()))
        #expect(store.today.sidechainWorkTokens == 40)

        store.includeSubagents = false
        store.recompute()
        #expect(store.today.workTokens == 100)            // sub-agent excluded, as before
        #expect(store.today.sidechainWorkTokens == 0)     // …and the split says so, not a stale 40
        #expect(store.sidechainShare(store.today) == 0)
    }

    @Test func noteIsSilentWhenThereIsNothingToReport() {
        let store = freshStore()
        #expect(store.sidechainNote(Totals()) == "")               // no data at all

        store.ingestForTesting(pair(at: Date()))
        #expect(!store.sidechainNote(store.today).isEmpty)

        store.includeSubagents = false                              // opted out → say nothing
        store.recompute()
        #expect(store.sidechainNote(store.today) == "")
    }

    /// `FiveHourBlockEngine` sums inline instead of going through `Totals.add`, so its split is
    /// accumulated separately and could drift. Pin it.
    @Test func activeBlockCarriesTheSplit() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let block = FiveHourBlockEngine.activeSession(from: pair(at: t0), pricing: pricing,
                                                      now: t0.addingTimeInterval(3600))
        #expect(block?.workTokens == 140)
        #expect(block?.sidechainWorkTokens == 40)
        #expect(block?.sidechainTotalTokens == 1000)
    }

    @Test func shareIsZeroForEmptyTotals() {
        let store = freshStore()
        #expect(store.sidechainShare(Totals()) == 0)
        #expect(store.sidechainTokens(Totals()) == 0)
    }
}
