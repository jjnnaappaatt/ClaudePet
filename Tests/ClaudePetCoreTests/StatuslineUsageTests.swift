import Testing
import Foundation
@testable import ClaudePetCore

private func isoString(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

private func writeTempJSON(_ json: String) -> String {
    let path = NSTemporaryDirectory() + "csl-\(UUID().uuidString).json"
    try! json.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// Reads the claude-statusline cache (a local file) — no token, no network. Mirrors the
/// real file shape: `{five_hour:{utilization,resets_at}, seven_day:{...}, …extra fields}`.
@Suite struct StatuslineUsageTests {

    @Test func parsesBothLimitsIgnoringExtraFields() {
        let future = Date().addingTimeInterval(3600)
        let path = writeTempJSON("""
        {"five_hour":{"utilization":14.0,"resets_at":"\(isoString(future))"},
         "seven_day":{"utilization":8.0,"resets_at":"\(isoString(future))"},
         "seven_day_opus":null,"extra_usage":{"is_enabled":false,"monthly_limit":null}}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let u = StatuslineUsageReader.read(path: path)
        #expect(u != nil)
        #expect(u?.fiveHour?.utilization == 14.0)
        #expect(u?.sevenDay?.utilization == 8.0)
        #expect(u?.fiveHour?.isUsable() == true)
        #expect(abs((u?.fiveHour?.fraction ?? 0) - 0.14) < 1e-9)
    }

    @Test func missingFileReturnsNil() {
        #expect(StatuslineUsageReader.read(path: "/tmp/nope-\(UUID().uuidString).json") == nil)
    }

    @Test func malformedReturnsNil() {
        let path = writeTempJSON("not json {{{")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(StatuslineUsageReader.read(path: path) == nil)
    }

    @Test func pastResetIsParsedButNotUsable() {
        let past = Date().addingTimeInterval(-3600)
        let path = writeTempJSON("{\"five_hour\":{\"utilization\":50.0,\"resets_at\":\"\(isoString(past))\"}}")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let u = StatuslineUsageReader.read(path: path)
        #expect(u?.fiveHour?.utilization == 50.0)
        #expect(u?.fiveHour?.isUsable() == false)   // its window already reset → stale
        #expect(u?.sevenDay == nil)
    }

    // Freshness gate: a cache the statusline wrote long ago is no longer "live", even if its
    // window hasn't reset yet — the percentages have simply gone stale.
    @Test func freshWhenJustWritten() {
        let now = Date()
        let u = StatuslineUsage(fiveHour: nil, sevenDay: nil, asOf: now)
        #expect(u.isFresh(now: now, maxAge: 1800))
    }

    @Test func freshExactlyAtBoundary() {
        let now = Date()
        let u = StatuslineUsage(fiveHour: nil, sevenDay: nil, asOf: now.addingTimeInterval(-1800))
        #expect(u.isFresh(now: now, maxAge: 1800))   // age == maxAge → still fresh
    }

    @Test func staleJustPastBoundary() {
        let now = Date()
        let u = StatuslineUsage(fiveHour: nil, sevenDay: nil, asOf: now.addingTimeInterval(-1801))
        #expect(u.isFresh(now: now, maxAge: 1800) == false)
    }
}

/// The store prefers Claude's real numbers (from the cache) to drive the gauges, but only
/// when present, enabled, and the window hasn't reset — otherwise it falls back to local.
@MainActor
@Suite struct ServerDrivenGaugeTests {

    private func freshDefaults() -> UserDefaults {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func writeCache(fiveHour: Double, sevenDay: Double, resetsInHours: Double) -> String {
        let reset = isoString(Date().addingTimeInterval(resetsInHours * 3600))
        return writeTempJSON("""
        {"five_hour":{"utilization":\(fiveHour),"resets_at":"\(reset)"},
         "seven_day":{"utilization":\(sevenDay),"resets_at":"\(reset)"}}
        """)
    }

    @Test func serverDataDrivesGaugeFractions() {
        let store = MetricsStore(defaults: freshDefaults())
        store.weightTokensByModel = false
        let path = writeCache(fiveHour: 14, sevenDay: 8, resetsInHours: 2)
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.statuslineCachePath = path
        // Local usage that would give a very different fallback % — proving server wins.
        store.ingestForTesting([TestSupport.entry(at: Date(), model: "claude-sonnet-4-6", input: 600, output: 400)])

        #expect(store.serverDriven5h)
        #expect(store.serverDriven7d)
        #expect(abs(store.blockFraction(unit: .tokens) - 0.14) < 1e-9)
        #expect(abs(store.weeklyFraction(unit: .tokens) - 0.08) < 1e-9)
        #expect(store.blockResetDate != nil)
    }

    @Test func toggleOffIgnoresServerData() {
        let store = MetricsStore(defaults: freshDefaults())
        let path = writeCache(fiveHour: 14, sevenDay: 8, resetsInHours: 2)
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.statuslineCachePath = path
        store.useStatuslineData = false
        store.recompute()

        #expect(store.serverUsage == nil)
        #expect(store.serverDriven5h == false)
    }

    @Test func expiredWindowFallsBackToLocal() {
        let store = MetricsStore(defaults: freshDefaults())
        store.weightTokensByModel = false
        let path = writeCache(fiveHour: 99, sevenDay: 99, resetsInHours: -1)   // already reset
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.statuslineCachePath = path
        store.ingestForTesting([TestSupport.entry(at: Date(), model: "claude-sonnet-4-6", input: 600, output: 400)])

        #expect(store.serverDriven5h == false)   // expired window not used
        #expect(store.blockFraction(unit: .tokens) != 0.99)
    }

    @Test func staleCacheFileFallsBackToLocal() {
        let store = MetricsStore(defaults: freshDefaults())
        store.weightTokensByModel = false
        // Window is still open (resets in 2h) but the file was written long ago → stale.
        let path = writeCache(fiveHour: 99, sevenDay: 99, resetsInHours: 2)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = Date().addingTimeInterval(-(MetricsStore.serverDataMaxAge + 60))
        try! FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        store.statuslineCachePath = path
        store.ingestForTesting([TestSupport.entry(at: Date(), model: "claude-sonnet-4-6", input: 600, output: 400)])

        #expect(store.serverDriven5h == false)   // fresh-window but stale file → not "live"
        #expect(store.serverDriven7d == false)
        #expect(store.blockFraction(unit: .tokens) != 0.99)   // local estimate, not the cached %
    }
}
