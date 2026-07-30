import SwiftUI

/// Uniform scale factor for the whole widget. Driving font sizes (rather than a
/// layer `.scaleEffect`) keeps text crisp at any size.
private struct WidgetScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

/// Floor for `scaledFont` sizes, applied BEFORE the scale multiply.
///
/// The type ramp was drawn for a 300–520pt widget card, where 7–9.5pt captions read fine next to a 17pt
/// figure. Blown up on a dashboard the same ramp leaves the grey labels ("work/day", "resets in", the
/// hour axis) disproportionately small — raising the global scale doesn't help, because it lifts the
/// headlines by the same factor. This compresses the bottom of the ramp instead. 0 = no floor (widget).
private struct MinScaledFontKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var widgetScale: CGFloat {
        get { self[WidgetScaleKey.self] }
        set { self[WidgetScaleKey.self] = newValue }
    }

    var minScaledFont: CGFloat {
        get { self[MinScaledFontKey.self] }
        set { self[MinScaledFontKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.widgetScale) private var scale
    @Environment(\.minScaledFont) private var floor
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: max(size, floor) * scale, weight: weight, design: design))
    }
}

extension View {
    /// Like `.font(.system(size:weight:design:))` but multiplied by the widget scale.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}
