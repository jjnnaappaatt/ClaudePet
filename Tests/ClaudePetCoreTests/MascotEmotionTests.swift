import Testing
import Foundation
@testable import ClaudePetCore

/// The pet's mood is derived from the **5-hour session alone**, reusing the gauge fraction — so it
/// tracks live server data or the local estimate identically. The weekly limit is a separate signal
/// (`groundCondition`); these tests pin that separation, because folding weekly back into the face
/// is the regression that would silently make the ground redundant.
@MainActor
@Suite struct MascotEmotionTests {

    private func freshStore() -> MetricsStore {
        let name = "mascot-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return TestSupport.store(defaults: d)
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
            (2, .celebrating), (15, .happy), (30, .content), (65, .neutral),
            (80, .focused), (90, .worried), (99, .alarmed), (100, .exhausted),
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

    /// The inverse of a test that used to assert `max(5h, weekly)`. A hammered weekly limit must NOT
    /// reach the pet's face — it belongs to the ground under it. Deleting this test rather than
    /// flipping it would leave the old coupling free to creep back unnoticed.
    @Test func weeklyPressureStaysOffTheFace() {
        let s = freshStore()
        let path = cachePath(fiveHour: 10, sevenDay: 97)   // weekly is nearly spent, the session isn't
        defer { try? FileManager.default.removeItem(atPath: path) }
        s.statuslineCachePath = path
        s.recompute()
        #expect(s.mascotEmotion == .happy, "the session has headroom, so the pet is happy")
        #expect(s.groundCondition == .cracked, "…and the week shows up underfoot instead")
    }

    /// The other direction, so neither signal can quietly swallow the other.
    @Test func sessionPressureStaysOffTheGround() {
        let s = freshStore()
        let path = cachePath(fiveHour: 97, sevenDay: 10)
        defer { try? FileManager.default.removeItem(atPath: path) }
        s.statuslineCachePath = path
        s.recompute()
        #expect(s.mascotEmotion == .alarmed)
        #expect(s.groundCondition == .lush)
    }
}
