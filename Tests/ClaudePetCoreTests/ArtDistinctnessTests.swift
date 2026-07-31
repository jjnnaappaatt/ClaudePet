import Testing
import Foundation
@testable import ClaudePetCore

/// Every mood and every ground state has to be *visibly* different from every other one.
///
/// This is the failure mode that adding variants invites: at 16×16 with a fixed set of eye poses and
/// accents, it is easy to add a mood that draws a face already in use. Then the enum has nine cases,
/// the tests all pass, and the user sees seven. A rendered preview sheet is the usual way to catch
/// it, which means catching it by eye, once — this pins it instead.
@Suite struct ArtDistinctnessTests {

    private func pixelsDiffering(_ a: [[UInt8]], _ b: [[UInt8]]) -> Int {
        zip(a, b).reduce(0) { acc, rows in
            acc + zip(rows.0, rows.1).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        }
    }

    /// Six pixels on a 16×16 grid. The number is calibrated against pairs that have shipped for
    /// months and are plainly distinct in use — `sleeping`/`neutral` sit at 7, `neutral`/`worried` at
    /// exactly 6 — so anything below it is genuinely too close. It undercounts on purpose: a differing
    /// pixel in an accent colour (a blue sweat drop, a red alarm mark) reads far louder than one in
    /// the body colour, and this metric can't tell them apart, so 6 body pixels is the pessimistic
    /// floor rather than the typical case.
    private static let minPixels = 6

    @Test func everyMoodLooksDifferent() {
        let all = MascotEmotion.allCases
        for i in 0 ..< all.count {
            for j in (i + 1) ..< all.count {
                let d = pixelsDiffering(MascotArt.face(all[i]), MascotArt.face(all[j]))
                #expect(d >= Self.minPixels,
                        "\(all[i].rawValue) and \(all[j].rawValue) differ by only \(d)px, so they read as the same face")
            }
        }
    }

    @Test func everyGroundStateLooksDifferent() {
        let all = GroundCondition.allCases
        for i in 0 ..< all.count {
            for j in (i + 1) ..< all.count {
                let d = pixelsDiffering(GroundArt.matrix(for: all[i]), GroundArt.matrix(for: all[j]))
                #expect(d >= Self.minPixels,
                        "\(all[i].rawValue) and \(all[j].rawValue) differ by only \(d)px")
            }
        }
    }
    @MainActor
    @Test func everySkyLooksDifferent() {
        let e = WeatherEngine()
        let all = WeatherCondition.allCases
        for i in 0 ..< all.count {
            for j in (i + 1) ..< all.count {
                let d = pixelsDiffering(e.staticFrame(for: all[i]), e.staticFrame(for: all[j]))
                #expect(d >= Self.minPixels,
                        "\(all[i].rawValue) and \(all[j].rawValue) differ by only \(d)px")
            }
        }
    }

}
