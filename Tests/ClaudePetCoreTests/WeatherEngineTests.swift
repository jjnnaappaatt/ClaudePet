import Testing
import Foundation
@testable import ClaudePetCore

@MainActor
@Suite struct WeatherEngineTests {

    /// Drive an engine through `seconds` of simulation in fixed steps from a reference epoch.
    private func run(_ e: WeatherEngine, seconds: Double, step: Double = 0.1) {
        var t = Date(timeIntervalSinceReferenceDate: 0)
        e.advance(to: t)                       // prime
        var elapsed = 0.0
        while elapsed < seconds {
            t = t.addingTimeInterval(step)
            e.advance(to: t)
            elapsed += step
        }
    }

    @Test func framesAreCorrectSize() {
        let e = WeatherEngine(seed: 1)
        e.setCondition(.storm)
        run(e, seconds: 1)
        #expect(e.currentFrame.count == WeatherEngine.rows)
        #expect(e.currentFrame.allSatisfy { $0.count == WeatherEngine.cols })
    }

    @Test func deterministicForSeed() {
        let a = WeatherEngine(seed: 42)
        let b = WeatherEngine(seed: 42)
        a.setCondition(.heavyStorm)
        b.setCondition(.heavyStorm)
        var t = Date(timeIntervalSinceReferenceDate: 0)
        a.advance(to: t); b.advance(to: t)
        for _ in 0..<60 {
            t = t.addingTimeInterval(1.0 / 6.0)
            a.advance(to: t); b.advance(to: t)
        }
        #expect(a.currentFrame == b.currentFrame)
        #expect(a.debugFlashCount == b.debugFlashCount)
    }

    @Test func clampsLargeTimeJumps() {
        let e = WeatherEngine(seed: 3)
        e.setCondition(.heavyStorm)
        let t = Date(timeIntervalSinceReferenceDate: 0)
        e.advance(to: t)
        e.advance(to: t.addingTimeInterval(100_000))   // wake-from-sleep jump
        #expect(e.currentFrame.count == WeatherEngine.rows)
        #expect(e.currentFrame.allSatisfy { $0.count == WeatherEngine.cols })
    }

    @Test func confettiIsOneShot() {
        let e = WeatherEngine(seed: 5)
        e.setCondition(.sunny)
        let t = Date(timeIntervalSinceReferenceDate: 0)
        e.advance(to: t)                       // prime
        e.trigger(.confetti)
        #expect(e.debugConfettiCount > 0)
        run(e, seconds: 3)                     // longer than max confetti life
        #expect(e.debugConfettiCount == 0)     // burst fully cleared, no repeat
    }

    @Test func heavyStormProducesLightning() {
        let e = WeatherEngine(seed: 9)
        e.setCondition(.heavyStorm)
        run(e, seconds: 12, step: 0.2)
        #expect(e.debugFlashCount >= 1)
    }

    @Test func clearSkyHasNoRain() {
        let e = WeatherEngine(seed: 11)
        e.setCondition(.clearSky)
        run(e, seconds: 2)
        #expect(e.debugRainCount == 0)
    }

    @Test func stormHasRain() {
        let e = WeatherEngine(seed: 13)
        e.setCondition(.storm)
        run(e, seconds: 1)
        #expect(e.debugRainCount > 0)
    }

    @Test func triggeredLightningShowsBolt() {
        let e = WeatherEngine(seed: 17)
        e.setCondition(.sunny)               // sunny normally has no bolt
        let t = Date(timeIntervalSinceReferenceDate: 0)
        e.advance(to: t)
        e.trigger(.lightningStrike)
        e.advance(to: t.addingTimeInterval(1.0 / 6.0))
        #expect(e.debugFlashing)             // bolt is active right after a strike
    }
}
