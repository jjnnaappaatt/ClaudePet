import Testing
import Foundation
@testable import ClaudePetCore

/// How often the store does its expensive work: one scan for a burst of file events, and no
/// full-history recompute on a timer tick that has nothing to show for it.
///
/// Both are invisible to every figure-checking test — an overlapping scan or a redundant recompute
/// produces the same numbers — and both were measured live: the widget sat at 100% of a core for
/// days, all of it in `refresh()` and `recompute()`.
@MainActor
@Suite struct RefreshSchedulingTests {

    private func defaults() -> UserDefaults {
        let name = "claudepet-sched-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func isolate(_ s: MetricsStore) {
        s.statuslineCachePath = TestSupport.noStatuslineCache
        s.statsCachePath = TestSupport.noStatsCache
        s.codexUsageCachePath = TestSupport.noCodexCache
        s.codexSessionsRoot = nil
        s.billingCycleDayOverride = 1
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudepet-sched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("proj"),
                                                withIntermediateDirectories: true)
        let line = #"{"type":"assistant","timestamp":"2026-06-05T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":7,"output_tokens":0}}}"#
        try (line + "\n").write(to: root.appendingPathComponent("proj/s.jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    private func waitFor(_ cond: () -> Bool, seconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func aBurstOfEventsRunsOneScan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = MetricsStore(defaults: defaults(), scannerRoot: root)
        isolate(s)

        for _ in 0..<25 { s.requestRefresh(.everything) }
        await waitFor { s.scansPerformed >= 1 && !s.isLoading }
        try? await Task.sleep(nanoseconds: 300_000_000)   // anything still queued would run now
        #expect(s.scansPerformed == 1)
        #expect(s.allTime.workTokens == 7)

        // Events arriving while that is settled queue exactly one more, after the spacing.
        for _ in 0..<10 { s.requestRefresh(.paths(["/elsewhere/x.jsonl"])) }
        await waitFor({ s.scansPerformed >= 2 }, seconds: MetricsStore.minRefreshSpacing + 3)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(s.scansPerformed == 2)
    }

    @Test func idleTicksSkipTheRecomputeUntilSomethingIsDue() throws {
        let s = TestSupport.store(defaults: defaults())
        isolate(s)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        // A Wednesday mid-morning, well away from any weekly/cycle boundary, with history days old.
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 10, minute: 10))!
        s.ingestForTesting([TestSupport.entry(at: now.addingTimeInterval(-3 * 86_400), input: 100)])
        s.recompute(now: now)
        #expect(s.lastUpdated == now)

        s.tick(now: now.addingTimeInterval(60))
        #expect(s.lastUpdated == now, "nothing changed — the tick must not redo the aggregate")

        // The hour rolls over: the hourly chart (and eventually the day) can change.
        let nextHour = cal.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 11))!
        s.tick(now: nextHour)
        #expect(s.lastUpdated == nextHour)

        // A side file being rewritten (here Claude Code's /stats cache) is due immediately.
        let side = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudepet-sched-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: side) }
        try Data("{}".utf8).write(to: side)
        s.statsCachePath = side.path
        s.recompute(now: nextHour)
        #expect(!s.recomputeIsDue(now: nextHour.addingTimeInterval(30)))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: side.path)
        #expect(s.recomputeIsDue(now: nextHour.addingTimeInterval(30)))
    }

    @Test func anActiveSessionEndingIsADeadline() throws {
        let s = TestSupport.store(defaults: defaults())
        isolate(s)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 10, minute: 10))!
        // Last activity 4h59m ago: the session expires one minute from now, before the hour ends.
        s.ingestForTesting([TestSupport.entry(at: now.addingTimeInterval(-(5 * 3600 - 60)), input: 100)])
        s.recompute(now: now)
        #expect(!s.recomputeIsDue(now: now.addingTimeInterval(30)))
        #expect(s.recomputeIsDue(now: now.addingTimeInterval(61)))
    }
}
