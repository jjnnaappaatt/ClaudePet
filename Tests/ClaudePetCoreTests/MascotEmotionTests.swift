import Testing
import Foundation
@testable import ClaudePetCore

/// The pet's mood is derived from limit pressure (whichever of 5h/weekly is closer), reusing
/// the gauge fractions — so it tracks live server data or the local estimate identically.
@MainActor
@Suite struct MascotEmotionTests {

    private func freshStore() -> MetricsStore {
        let name = "mascot-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return MetricsStore(defaults: d)
    }

    /// Writes a statusline-cache fixture with given utilization (so fractions are deterministic).
    private func cachePath(fiveHour: Double, sevenDay: Double, resetsInHours: Double = 2) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reset = f.string(from: Date().addingTimeInterval(resetsInHours * 3600))
        let json = """
        {"five_hour":{"utilization":\(fiveHour),"resets_at":"\(reset)"},
         "seven_day":{"utilization":\(sevenDay),"resets_at":"\(reset)"}}
        """
        let path = NSTemporaryDirectory() + "mascot-cache-\(UUID().uuidString).json"
        try! json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func sleepsWhenNoActivity() {
        let s = freshStore()
        s.useStatuslineData = false
        s.recompute()                      // no entries, no cache → no active session
        #expect(s.mascotEmotion == .sleeping)
    }

    @Test func moodTracksUsagePressure() {
        let cases: [(Double, MascotEmotion)] = [
            (2, .celebrating), (30, .happy), (65, .neutral), (90, .worried), (99, .alarmed),
        ]
        for (util, expected) in cases {
            let s = freshStore()
            let path = cachePath(fiveHour: util, sevenDay: 0)
            defer { try? FileManager.default.removeItem(atPath: path) }
            s.statuslineCachePath = path
            s.recompute()
            #expect(s.mascotEmotion == expected, "utilization \(util) should map to \(expected)")
        }
    }

    @Test func takesTheCloserOfTheTwoLimits() {
        let s = freshStore()
        let path = cachePath(fiveHour: 10, sevenDay: 97)   // weekly is the pressure
        defer { try? FileManager.default.removeItem(atPath: path) }
        s.statuslineCachePath = path
        s.recompute()
        #expect(s.mascotEmotion == .alarmed)
    }
}
