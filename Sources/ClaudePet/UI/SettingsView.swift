import SwiftUI
import AppKit
import ClaudePetCore

/// Settings: 5-hour budget + unit, include-subagents, launch-at-login, editable pricing.
struct SettingsView: View {
    @Environment(MetricsStore.self) private var metricsEnv

    @State private var loginOn = LoginItem.isEnabled
    @State private var loginMessage: String?

    var body: some View {
        @Bindable var metrics = metricsEnv

        Form {
            Section("5-hour budget") {
                Picker("Gauge unit", selection: $metrics.budgetUnit) {
                    Text("Tokens").tag(BudgetUnit.tokens)
                    Text("US$").tag(BudgetUnit.usd)
                }
                .pickerStyle(.segmented)
                .onChange(of: metrics.budgetUnit) { persist() }

                if metrics.budgetUnit == .tokens {
                    LabeledContent("Budget (tokens)") {
                        TextField("tokens", value: $metrics.tokenBudget, format: .number)
                            .frame(width: 120).multilineTextAlignment(.trailing)
                            .onChange(of: metrics.tokenBudget) { persist() }
                    }
                } else {
                    LabeledContent("Budget (US$)") {
                        TextField("usd", value: $metrics.costBudget, format: .number)
                            .frame(width: 120).multilineTextAlignment(.trailing)
                            .onChange(of: metrics.costBudget) { persist() }
                    }
                }
            }

            Section("Appearance") {
                HStack {
                    Text("Widget size")
                    Slider(value: $metrics.widgetScale, in: 0.8...1.6, step: 0.05)
                        .onChange(of: metrics.widgetScale) { persist() }
                    Text("\(Int((metrics.widgetScale * 100).rounded()))%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

            Section("Usage") {
                Toggle("Include subagent usage", isOn: $metrics.includeSubagents)
                    .onChange(of: metrics.includeSubagents) { persist() }

                Toggle("Launch at login", isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in
                        loginMessage = LoginItem.setEnabled(on)
                        loginOn = LoginItem.isEnabled
                    }
                Text(loginMessage ?? "Status: \(LoginItem.statusDescription)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pricing — US$ per 1M tokens (eff. \(metrics.pricing.effectiveDate))") {
                ForEach(ModelFamily.allCases.filter { $0 != .other }, id: \.self) { family in
                    HStack {
                        Text(family.displayName).frame(width: 64, alignment: .leading)
                        LabeledContent("in") {
                            TextField("in", value: rate(metrics, family, \.inputPerM), format: .number)
                                .frame(width: 64).multilineTextAlignment(.trailing)
                                .onChange(of: metrics.pricing) { persist() }
                        }
                        LabeledContent("out") {
                            TextField("out", value: rate(metrics, family, \.outputPerM), format: .number)
                                .frame(width: 64).multilineTextAlignment(.trailing)
                        }
                    }
                }
                Text("Cache: read 0.1×, write 1.25×/2× input. Cost is notional API-equivalent.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset pricing to defaults") {
                    metrics.pricing = .default
                    persist()
                }
            }

            Section {
                HStack {
                    Text("ClaudePet 0.1.0").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit ClaudePet") { NSApplication.shared.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 500)
    }

    private func persist() { metricsEnv.saveConfigAndRecompute() }

    private func rate(_ metrics: MetricsStore, _ family: ModelFamily,
                      _ keyPath: WritableKeyPath<ModelPrice, Double>) -> Binding<Double> {
        Binding(
            get: { metrics.pricing.prices[family.rawValue]?[keyPath: keyPath] ?? 0 },
            set: { metrics.pricing.prices[family.rawValue]?[keyPath: keyPath] = $0 }
        )
    }
}
