import Foundation

/// The app's frame rate for the pixel-art layers — one place, so the mascot and its weather can't
/// drift onto different clocks.
///
/// **Why 15 and not "whatever looks smooth".** These layers render onto a fixed 16×22 lattice and
/// positions are floored to whole cells, so sub-cell motion is invisible: a drop either occupies row
/// 7 or row 8, never in between. That makes the frame rate a *correctness* constraint rather than a
/// smoothness preference — if a raindrop's speed exceeds one row per frame it skips rows entirely,
/// and what the eye sees is a column of dots blinking on and off at different heights rather than
/// anything falling.
///
/// That is exactly what 6 fps did: heavy rain falls at up to `WeatherEngine.maxRainRowsPerSecond`
/// ≈ 13.8 rows/s, so each frame moved a drop **2.3 rows** and the rain read as sparse and broken.
/// 15 fps puts the fastest drop under one row per frame (0.92), which is the point at which motion
/// becomes continuous. `WeatherEngineTests` pins the relationship, so raising a rain speed without
/// raising this fails a test rather than quietly degrading the animation.
///
/// Confetti is deliberately exempt: it accelerates under gravity to roughly 26 rows/s by the end of
/// its fall, and matching that would mean ~30 fps for the sake of a two-second burst. A celebration
/// looking energetic and slightly stroboscopic is fine; steady rain looking broken is not.
public enum AnimationRate {
    /// Normal draw rate for `MascotView`, `WeatherView` and anything else on the pixel lattice.
    public static let standard: Double = 15

    /// Low Power Mode. Still animated — just coarse. Both views also stop entirely when the panel is
    /// occluded or Reduce Motion is on, which is where the real saving comes from.
    public static let lowPower: Double = 6

    /// The rate to draw at right now.
    public static var current: Double {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? lowPower : standard
    }
}
