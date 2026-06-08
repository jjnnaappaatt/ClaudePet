import SwiftUI
import ClaudePetCore

/// What you PAY this cycle vs the API-equivalent value of what you used, plus a minimal
/// usage-credits readout (spent / limit + balance) when you've entered credit details.
struct BillingLineView: View {
    @Environment(MetricsStore.self) private var metrics

    private var totalPaid: Double { metrics.monthlyPrice + metrics.creditSpent }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Paid + API value
            HStack(spacing: 5) {
                Text("Paid").foregroundStyle(Theme.textSecondary)
                Text(metrics.monthlyPrice > 0 ? Format.currency(metrics.monthlyPrice) : "—")
                    .foregroundStyle(Theme.textPrimary)
                Text("·").foregroundStyle(Theme.textSecondary.opacity(0.4))
                Text("API value").foregroundStyle(Theme.textSecondary)
                Text(Format.currency(metrics.cycle.costUSD)).foregroundStyle(Theme.claudeCoral)
                if totalPaid > 0 {
                    Spacer(minLength: 4)
                    Text("\(Int((metrics.cycle.costUSD / totalPaid).rounded()))×")
                        .foregroundStyle(Theme.claudeCoral)
                }
            }
            // Usage credits (only when entered) — minimal
            if metrics.creditLimit > 0 {
                let pct = Int((metrics.creditSpent / metrics.creditLimit * 100).rounded())
                HStack(spacing: 5) {
                    Text("Credits").foregroundStyle(Theme.textSecondary)
                    Text("\(Format.currency(metrics.creditSpent)) / \(Format.currency(metrics.creditLimit))")
                        .foregroundStyle(Theme.textPrimary)
                    Text("(\(pct)%)").foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 4)
                    Text("bal \(Format.currency(metrics.creditBalance))")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .scaledFont(10)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .help("Paid = plan fee + credit spend you enter. API value = this cycle's usage at API rates. Usage-credit figures are server-side; enter them in Settings → Billing to show them here.")
    }
}
