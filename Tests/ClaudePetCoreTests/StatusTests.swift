import Testing
import Foundation
@testable import ClaudePetCore

/// The one-glance redesign leads with the BINDING limit (closer of 5h / weekly) plus a
/// plain-language status word + colour-blind-safe level. These are derived from the same
/// gauge fractions the bars use, so they track live server data or the local estimate.
@MainActor
@Suite struct StatusTests {

    private func freshStore() -> MetricsStore {
        let name = "status-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return MetricsStore(defaults: d)
    }

    /// Statusline-cache fixture so fractions are deterministic (utilization is 0–100).
    private func store(fiveHour: Double, sevenDay: Double) -> MetricsStore {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reset = f.string(from: Date().addingTimeInterval(2 * 3600))
        let json = """
        {"five_hour":{"utilization":\(fiveHour),"resets_at":"\(reset)"},
         "seven_day":{"utilization":\(sevenDay),"resets_at":"\(reset)"}}
        """
        let path = NSTemporaryDirectory() + "status-\(UUID().uuidString).json"
        try! json.write(toFile: path, atomically: true, encoding: .utf8)
        let s = freshStore()
        s.statuslineCachePath = path
        s.recompute()
        return s
    }

    @Test func bindingPicksTheCloserLimit() {
        let s = store(fiveHour: 10, sevenDay: 80)
        #expect(s.bindingIsWeekly == true)
        #expect(abs(s.bindingFraction - 0.80) < 0.001)

        let s2 = store(fiveHour: 60, sevenDay: 20)
        #expect(s2.bindingIsWeekly == false)
        #expect(abs(s2.bindingFraction - 0.60) < 0.001)
    }

    @Test func statusLevelThresholds() {
        #expect(store(fiveHour: 50, sevenDay: 0).statusLevel == .ok)
        #expect(store(fiveHour: 85, sevenDay: 0).statusLevel == .warn)
        #expect(store(fiveHour: 97, sevenDay: 0).statusLevel == .over)
    }

    @Test func statusWordTracksMood() {
        #expect(store(fiveHour: 30, sevenDay: 0).statusWord == "Cruising")
        #expect(store(fiveHour: 65, sevenDay: 0).statusWord == "Steady")
        #expect(store(fiveHour: 90, sevenDay: 0).statusWord == "Getting tight")
        #expect(store(fiveHour: 99, sevenDay: 0).statusWord == "At the wall")
    }

    @Test func statusLineNamesBindingLimitAndReset() {
        let weeklyBound = store(fiveHour: 10, sevenDay: 90).statusLine()
        #expect(weeklyBound.contains("weekly limit"))
        #expect(weeklyBound.contains("resets in"))

        let sessionBound = store(fiveHour: 90, sevenDay: 10).statusLine()
        #expect(sessionBound.contains("session"))
    }
}
