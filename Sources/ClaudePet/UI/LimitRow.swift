import SwiftUI
import ClaudePetCore

/// One limit in the landscape "LIMITS" block: label + %, with a thin bar.
/// Only the binding (closer) limit wears the accent colour; the other stays neutral —
/// so each card spends its coral exactly once.
struct LimitRow: View {
    let label: String
    let fraction: Double
    let isBinding: Bool
    let level: StatusLevel

    @Environment(\.widgetScale) private var scale

    private var accent: Color { isBinding ? Theme.color(for: level) : Color.white.opacity(0.30) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack {
                Text(label)
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(isBinding ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .scaledFont(15, weight: .semibold, design: .rounded)
                    .foregroundStyle(isBinding ? accent : Theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(accent)
                        .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 6 * scale)
        }
    }
}
