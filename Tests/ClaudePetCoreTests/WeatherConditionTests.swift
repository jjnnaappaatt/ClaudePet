import Testing
import Foundation
@testable import ClaudePetCore

/// Weather is a pure function of the pet's mood, so the face and the sky can never disagree.
@Suite struct WeatherConditionTests {

    @Test func mapsEachEmotionToCondition() {
        let cases: [(MascotEmotion, WeatherCondition)] = [
            (.sleeping,    .clearSky),
            (.celebrating, .sunny),
            (.happy,       .sunny),
            (.neutral,     .cloudy),
            (.worried,     .storm),
            (.alarmed,     .heavyStorm),
        ]
        for (emotion, expected) in cases {
            #expect(WeatherCondition.from(emotion) == expected,
                    "\(emotion) should map to \(expected)")
        }
    }

    @Test func everyEmotionHasAMapping() {
        // Exhaustive: no mood is left without a sky (guards future MascotEmotion additions).
        for emotion in MascotEmotion.allCases {
            _ = WeatherCondition.from(emotion)
        }
        #expect(MascotEmotion.allCases.count == 6)
    }

    @MainActor
    @Test func storeWeatherMatchesMood() {
        let name = "weather-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let s = MetricsStore(defaults: d)
        s.useStatuslineData = false
        s.recompute()                       // idle → sleeping → clearSky
        #expect(s.mascotEmotion == .sleeping)
        #expect(s.weatherCondition == .clearSky)
    }
}
