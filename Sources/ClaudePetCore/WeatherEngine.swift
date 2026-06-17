import Foundation

/// Simulates the pet's ambient weather and rasterises it to a pixel frame — drawn by the app's
/// `PixelMatrixRenderer`, exactly like the mascot, so weather pixels align with the pet.
///
/// The grid is taller than the pet (16 wide × 22 tall) so the sky — sun, clouds, the top of the
/// rain — sits *above* the pet rather than on top of it. The pet is overlaid bottom-aligned, so it
/// stands beneath the weather.
///
/// Plain `@MainActor` class (not `@Observable`): it's mutated inside a `TimelineView` draw closure,
/// which drives the cadence — the same rationale as `MascotEngine`.
@MainActor
public final class WeatherEngine {
    public static let cols = 16              // matches the mascot's width so pixels line up
    public static let rows = 22              // taller than the pet → clear sky overhead
    private static let skyRows = 6           // rows of open sky above the bottom-aligned pet

    /// Palette indices the renderer maps to colors (see `Pal`). Mascot owns 1–8; weather owns 7,9–13.
    private enum Ink {
        static let rain: UInt8 = 7
        static let cloudLight: UInt8 = 9
        static let cloudDark: UInt8 = 10
        static let sun: UInt8 = 11
        static let bolt: UInt8 = 12
        static let confettiA: UInt8 = 13     // confetti also reuses coral(1), belly(2), white(4)
    }
    private static let confettiPalette: [UInt8] = [1, 2, 4, 11, 13]

    private struct Drop { var x, y, vy: Double; var tall: Bool }
    private struct Confetto { var x, y, vx, vy, life: Double; var color: UInt8 }
    private struct Cloud { var x, y, vx: Double; var dark: Bool; var big: Bool }

    private var rng: SeededRNG
    private var condition: WeatherCondition = .clearSky
    private var rain: [Drop] = []
    private var confetti: [Confetto] = []
    private var clouds: [Cloud] = []
    private var sunPhase = 0.0
    private var lightningTimer = 3.0          // seconds to the next ambient flash (heavyStorm)
    private var flashTTL = 0.0                // > 0 → a bolt is currently showing
    private var flashCount = 0               // diagnostics
    private var lastTick: Date?

    public private(set) var currentFrame: [[UInt8]]

    public init(seed: UInt64 = 0x57EA_7E) {  // distinct stream from the mascot's RNG
        rng = SeededRNG(seed: seed)
        currentFrame = Self.blank()
    }

    // MARK: - Public API (mirrors MascotEngine)

    /// Switch the steady weather. Reseeds rain/cloud pools to the new condition's targets; leaves
    /// confetti alone (it's event-driven, independent of the steady sky).
    public func setCondition(_ c: WeatherCondition) {
        guard c != condition else { return }
        condition = c
        seedClouds()
        seedRain()
        if c == .heavyStorm { lightningTimer = 2.5 }
    }

    /// Fire a one-shot moment: a confetti burst, or a forced lightning strike.
    public func trigger(_ event: WeatherEvent) {
        switch event {
        case .confetti:
            for _ in 0..<22 {
                confetti.append(Confetto(x: rand(0, Double(Self.cols)), y: rand(-3, 1),
                                         vx: rand(-3, 3), vy: rand(-2, 1), life: rand(1.4, 2.1),
                                         color: Self.confettiPalette[Int(rng.next() % UInt64(Self.confettiPalette.count))]))
            }
        case .lightningStrike:
            flashTTL = max(flashTTL, 0.5)
            flashCount += 1
        }
    }

    /// Advance the simulation to `date`. dt is clamped so waking from a pause doesn't fast-forward
    /// (same guard as `MascotEngine.advance`).
    public func advance(to date: Date) {
        guard let last = lastTick else { lastTick = date; rasterize(); return }
        lastTick = date
        let dt = min(date.timeIntervalSince(last), 0.5)
        guard dt > 0 else { return }
        step(dt)
        rasterize()
    }

    /// Drop accumulated time on resume so particles pick up smoothly (mirrors `MascotEngine.resetClock`).
    public func resetClock() { lastTick = nil }

    /// A single still frame representing `condition`, for Reduce Motion / paused rendering — no
    /// live particle motion, deterministic layout.
    public func staticFrame(for c: WeatherCondition) -> [[UInt8]] {
        var g = Self.blank()
        switch c {
        case .clearSky:
            drawSun(into: &g, rays: true)
        case .sunny:
            drawSun(into: &g, rays: true)
            drawCloud(into: &g, cx: 11, cy: 2, dark: false, big: false)
        case .cloudy:
            drawCloud(into: &g, cx: 4, cy: 1, dark: false, big: false)
            drawCloud(into: &g, cx: 11, cy: 3, dark: false, big: true)
        case .storm:
            drawCloud(into: &g, cx: 8, cy: 1, dark: true, big: true)
            for (r, c) in [(5, 2), (8, 4), (7, 12), (10, 13), (12, 7), (14, 10)] { plot(&g, r, c, Ink.rain) }
        case .heavyStorm:
            drawCloud(into: &g, cx: 8, cy: 1, dark: true, big: true)
            for (r, c) in [(5, 1), (8, 3), (11, 2), (6, 13), (9, 14), (12, 12), (10, 7), (14, 5), (16, 10)] {
                plot(&g, r, c, Ink.rain)
            }
            for (r, c) in [(3, 10), (4, 11), (5, 10), (6, 11), (7, 10)] { plot(&g, r, c, Ink.bolt) }
        }
        return g
    }

    // Diagnostics (used by tests).
    public var debugRainCount: Int { rain.count }
    public var debugConfettiCount: Int { confetti.count }
    public var debugCloudCount: Int { clouds.count }
    public var debugFlashCount: Int { flashCount }
    public var debugFlashing: Bool { flashTTL > 0 }

    // MARK: - Simulation

    private func step(_ dt: Double) {
        sunPhase += dt

        // Clouds drift sideways and wrap.
        for i in clouds.indices {
            clouds[i].x += clouds[i].vx * dt
            if clouds[i].x > Double(Self.cols) + 2 { clouds[i].x = -2 }
            if clouds[i].x < -2 { clouds[i].x = Double(Self.cols) + 2 }
        }

        // Rain falls; respawn at the top when it leaves the bottom.
        for i in rain.indices {
            rain[i].y += rain[i].vy * dt
            if rain[i].y > Double(Self.rows) {
                rain[i].y = rand(-3, 0)
                rain[i].x = rand(0, Double(Self.cols))
            }
        }

        // Confetti: gravity + drift + fade; remove when spent.
        for i in confetti.indices {
            confetti[i].vy += 13 * dt                 // gravity (rows/s²)
            confetti[i].x += confetti[i].vx * dt
            confetti[i].y += confetti[i].vy * dt
            confetti[i].life -= dt
        }
        confetti.removeAll { $0.life <= 0 || $0.y > Double(Self.rows) + 1 }

        // Ambient lightning cadence in the heavy storm.
        if condition == .heavyStorm {
            lightningTimer -= dt
            if lightningTimer <= 0 {
                flashTTL = max(flashTTL, 0.34)        // ~2 frames at 6 fps
                flashCount += 1
                lightningTimer = rand(2.5, 5.0)
            }
        }
        if flashTTL > 0 { flashTTL -= dt }
    }

    private func rasterize() {
        var g = Self.blank()
        // Back-to-front: sun, clouds, rain, bolt, confetti (confetti on top).
        if condition == .clearSky || condition == .sunny { drawSun(into: &g, rays: condition == .clearSky) }
        for c in clouds { drawCloud(into: &g, cx: c.x, cy: c.y, dark: c.dark, big: c.big) }
        for d in rain {
            let r = Int(d.y.rounded(.down)), c = Int(d.x.rounded(.down))
            plot(&g, r, c, Ink.rain)
            if d.tall { plot(&g, r - 1, c, Ink.rain) }
        }
        if flashTTL > 0 { drawBolt(into: &g) }
        for p in confetti { plot(&g, Int(p.y.rounded(.down)), Int(p.x.rounded(.down)), p.color) }
        currentFrame = g
    }

    // MARK: - Seeding

    private func seedRain() {
        let target: Int
        switch condition {
        case .storm:      target = 12
        case .heavyStorm: target = 20
        default:          target = 0
        }
        let tall = condition == .heavyStorm
        let speed = condition == .heavyStorm ? 12.0 : 9.0
        rain = (0..<target).map { _ in
            Drop(x: rand(0, Double(Self.cols)), y: rand(0, Double(Self.rows)),
                 vy: speed * rand(0.85, 1.15), tall: tall)
        }
    }

    private func seedClouds() {
        // All clouds live in the top sky band so they sit clear of the pet below.
        switch condition {
        case .clearSky:
            clouds = []
        case .sunny:
            clouds = [Cloud(x: 11, y: 2, vx: 0.5, dark: false, big: false)]
        case .cloudy:
            clouds = [Cloud(x: 4, y: 1, vx: 0.5, dark: false, big: false),
                      Cloud(x: 11, y: 3, vx: -0.4, dark: false, big: true)]
        case .storm:
            clouds = [Cloud(x: 8, y: 1, vx: 0.3, dark: true, big: true)]
        case .heavyStorm:
            clouds = [Cloud(x: 7, y: 1, vx: 0.25, dark: true, big: true),
                      Cloud(x: 13, y: 2, vx: -0.3, dark: true, big: false)]
        }
    }

    // MARK: - Drawing primitives (grid-space)

    private static func blank() -> [[UInt8]] {
        [[UInt8]](repeating: [UInt8](repeating: 0, count: cols), count: rows)
    }

    private func plot(_ g: inout [[UInt8]], _ r: Int, _ c: Int, _ v: UInt8) {
        guard r >= 0, r < Self.rows, c >= 0, c < Self.cols else { return }
        g[r][c] = v
    }

    private func drawSun(into g: inout [[UInt8]], rays: Bool) {
        // Small sun tucked in the top-left of the sky band (well above the pet).
        for (r, c) in [(1, 1), (1, 2), (2, 1), (2, 2)] { plot(&g, r, c, Ink.sun) }
        if rays {
            // Gentle twinkle: rays toggle with the sun phase.
            let on = Int(sunPhase * 1.5) % 2 == 0
            if on { for (r, c) in [(0, 1), (1, 0), (3, 2), (2, 3)] { plot(&g, r, c, Ink.sun) } }
        }
    }

    private func drawCloud(into g: inout [[UInt8]], cx: Double, cy: Double, dark: Bool, big: Bool) {
        let color = dark ? Ink.cloudDark : Ink.cloudLight
        let r = Int(cy.rounded(.down)), c = Int(cx.rounded(.down))
        // A small puff blob; `big` adds a wider lower row.
        var cells = [(0, 0), (0, 1), (0, -1), (-1, 0), (-1, 1)]
        if big { cells += [(0, 2), (0, -2), (1, 0), (1, 1), (1, -1)] }
        for (dr, dc) in cells { plot(&g, r + dr, c + dc, color) }
    }

    private func drawBolt(into g: inout [[UInt8]]) {
        // A short jagged bolt hanging from a cloud, in a side column clear of the pet's body.
        for (r, c) in [(3, 11), (4, 11), (5, 10), (6, 11), (7, 10), (8, 10)] { plot(&g, r, c, Ink.bolt) }
    }

    // MARK: - RNG helpers

    /// Uniform Double in [lo, hi) from the seeded generator (mirrors MascotMachine's roll style).
    private func rand(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * (Double(rng.next() % 100_000) / 100_000.0)
    }
}
