import Testing
import Foundation
@testable import ClaudePetCore

/// One-shot weather events (confetti on a fresh 5h window, lightning on crossing into the danger
/// zone) must fire exactly once per transition — never on first load, never repeatedly.
@MainActor
@Suite struct WeatherEdgeTests {

    private func freshStore() -> MetricsStore {
        let name = "weather-edge-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let s = MetricsStore(defaults: d)
        s.useStatuslineData = false
        return s
    }

    /// Writes/overwrites a statusline-cache fixture with a *pinned* reset time, so two writes with
    /// the same `reset` keep the window identity stable (only utilization changes).
    @discardableResult
    private func writeCache(to path: String? = nil, fiveHour: Double, sevenDay: Double,
                            reset: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let r = f.string(from: reset)
        let json = """
        {"five_hour":{"utilization":\(fiveHour),"resets_at":"\(r)"},
         "seven_day":{"utilization":\(sevenDay),"resets_at":"\(r)"}}
        """
        let p = path ?? (NSTemporaryDirectory() + "weather-edge-\(UUID().uuidString).json")
        try! json.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    private func futureReset(hours: Double = 2) -> Date { Date().addingTimeInterval(hours * 3600) }

    @Test func firstLoadFiresNoEvents() {
        let s = freshStore()
        let reset = futureReset()
        s.statuslineCachePath = writeCache(fiveHour: 99, sevenDay: 99, reset: reset)
        s.useStatuslineData = true
        defer { try? FileManager.default.removeItem(atPath: s.statuslineCachePath) }
        s.recompute()                                  // prime only
        #expect(s.consumeWeatherEvents().isEmpty)      // no startup confetti/lightning
    }

    @Test func freshLocalWindowFiresConfettiOnce() {
        let s = freshStore()
        s.recompute()                                  // prime: idle, no active block
        #expect(s.consumeWeatherEvents().isEmpty)

        s.ingestForTesting([TestSupport.entry(at: Date(), input: 600, output: 400)])
        #expect(s.activeBlock != nil)                  // a window is now active
        #expect(s.consumeWeatherEvents() == [.confetti])

        s.recompute()                                  // same window → no refire
        #expect(s.consumeWeatherEvents().isEmpty)
    }

    @Test func serverWindowRollFiresConfetti() {
        let s = freshStore()
        s.useStatuslineData = true
        let path = NSTemporaryDirectory() + "weather-roll-\(UUID().uuidString).json"
        s.statuslineCachePath = path
        defer { try? FileManager.default.removeItem(atPath: path) }

        writeCache(to: path, fiveHour: 40, sevenDay: 0, reset: futureReset(hours: 2))
        s.recompute()                                  // prime
        #expect(s.consumeWeatherEvents().isEmpty)

        writeCache(to: path, fiveHour: 40, sevenDay: 0, reset: futureReset(hours: 3))   // window rolled
        s.recompute()
        #expect(s.consumeWeatherEvents() == [.confetti])
    }

    @Test func crossingIntoAlarmedFiresLightningOnce() {
        let s = freshStore()
        s.useStatuslineData = true
        let path = NSTemporaryDirectory() + "weather-alarm-\(UUID().uuidString).json"
        s.statuslineCachePath = path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reset = futureReset()                       // pinned → same window throughout

        writeCache(to: path, fiveHour: 90, sevenDay: 0, reset: reset)
        s.recompute()                                   // prime: worried
        #expect(s.mascotEmotion == .worried)
        #expect(s.consumeWeatherEvents().isEmpty)

        writeCache(to: path, fiveHour: 99, sevenDay: 0, reset: reset)
        s.recompute()                                   // → alarmed
        #expect(s.mascotEmotion == .alarmed)
        #expect(s.consumeWeatherEvents() == [.lightningStrike])

        writeCache(to: path, fiveHour: 99, sevenDay: 0, reset: reset)
        s.recompute()                                   // stays alarmed → no refire
        #expect(s.consumeWeatherEvents().isEmpty)
    }

    @Test func freshWindowThatLandsAlarmedFiresBoth() {
        let s = freshStore()
        s.recompute()                                   // prime: idle
        #expect(s.consumeWeatherEvents().isEmpty)

        let path = NSTemporaryDirectory() + "weather-both-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        writeCache(to: path, fiveHour: 99, sevenDay: 0, reset: futureReset())
        s.statuslineCachePath = path
        s.useStatuslineData = true
        s.recompute()                                   // idle → active AND alarmed at once
        #expect(s.consumeWeatherEvents() == [.confetti, .lightningStrike])
    }
}
