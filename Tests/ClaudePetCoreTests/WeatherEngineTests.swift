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
    /// The frame rate is a correctness constraint here, not a smoothness preference.
    ///
    /// Positions are floored onto a 16×22 lattice, so a drop is either on row 7 or row 8 — never
    /// between. If its speed exceeds one row per frame it skips rows outright, and the rain reads as
    /// dots blinking at unrelated heights instead of falling. At the old 6 fps the fastest drop moved
    /// 2.3 rows a frame, which is what made heavy rain look sparse and broken.
    @Test func rainNeverSkipsARowAtTheStandardFrameRate() {
        let rowsPerFrame = WeatherEngine.maxRainRowsPerSecond / AnimationRate.standard
        #expect(rowsPerFrame < 1.0,
                "fastest drop moves \(rowsPerFrame) rows/frame — raise AnimationRate.standard or lower the rain speed")
    }

    /// Low Power Mode is allowed to be coarse, but not a slideshow: below ~4 fps the clouds visibly
    /// jump rather than drift, which reads as a stutter bug rather than as a battery saving.
    @Test func lowPowerRateStaysAboveASlideshow() {
        #expect(AnimationRate.lowPower >= 4)
        #expect(AnimationRate.lowPower < AnimationRate.standard)
    }

}
