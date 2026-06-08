import SwiftUI
import AppKit
import ClaudePetCore

/// Settings: budgets, calibration, billing, and appearance.
struct SettingsView: View {
    @Environment(MetricsStore.self) private var metricsEnv

    @State private var loginOn = LoginItem.isEnabled
    @State private var loginMessage: String?
    @State private var sessionPct = ""
    @State private var weeklyPct = ""
    @State private var resetMin = ""
    @State private var weeklyResetDay = ""
    @State private var weeklyResetHour = ""
    @State private var weeklyResetMin = ""
    @State private var calibrateMsg: String?
    @State private var resetMsg: String?
    @State private var weeklyResetMsg: String?
    @FocusState private var focus: Field?

    private enum Field { case session, weekly, resetMin, weeklyResetDay, weeklyResetHour, weeklyResetMin, sessionBudget, weeklyBudget, price, creditSpent, creditLimit, creditBalance }

    var body: some View {
        @Bindable var metrics = metricsEnv

        Form {
            // MARK: Budget
            Section {
                LabeledContent("Plan", value: metrics.plan.displayName)
                Picker("Gauge unit", selection: $metrics.budgetUnit) {
                    Text("Tokens").tag(BudgetUnit.tokens)
                    Text("US$").tag(BudgetUnit.usd)
                }
                .pickerStyle(.segmented)
                .onChange(of: metrics.budgetUnit) { persist() }

                if metrics.budgetUnit == .tokens {
                    Toggle("Weight tokens by model cost", isOn: $metrics.weightTokensByModel)
                        .onChange(of: metrics.weightTokensByModel) { persist() }
                    caption("Counts an Opus token heavier than a Haiku one (relative to Sonnet), so the gauge tracks limit consumption like Claude does instead of summing tokens flat.")
                }

                Toggle("Use my plan's budget", isOn: $metrics.autoBudgetFromPlan)
                    .onChange(of: metrics.autoBudgetFromPlan) { persist() }

                if metrics.autoBudgetFromPlan {
                    LabeledContent("Session budget", value: budgetText(metrics.plan.tokenBudget, metrics.plan.costBudget))
                    LabeledContent("Weekly budget", value: budgetText(metrics.plan.weeklyTokenBudget, metrics.plan.weeklyCostBudget))
                    caption("Anthropic doesn't publish exact caps — these are tier-scaled estimates. Turn off to set your own, or use Calibrate below.")
                } else if metrics.budgetUnit == .tokens {
                    numberRow("Session budget", value: $metrics.tokenBudget, focus: .sessionBudget)
                    numberRow("Weekly budget", value: $metrics.weeklyTokenBudget, focus: .weeklyBudget)
                } else {
                    decimalRow("Session budget ($)", value: $metrics.costBudget, focus: .sessionBudget)
                    decimalRow("Weekly budget ($)", value: $metrics.weeklyCostBudget, focus: .weeklyBudget)
                }
            } header: { Text("5-hour & weekly budget") }

            // MARK: Calibration
            Section {
                caption("Open Claude → Settings → Usage and enter the % shown, then Calibrate. The widget can't read Claude's exact numbers (server-side), so this fits the budgets to match.")
                pctRow("Current session", text: $sessionPct, focus: .session)
                pctRow("Weekly (all models)", text: $weeklyPct, focus: .weekly)
                HStack {
                    Button("Calibrate budgets") { calibrate() }
                    Spacer()
                    if let calibrateMsg { Text(calibrateMsg).font(.caption).foregroundStyle(.secondary) }
                }

                Divider()
                HStack {
                    Text("Session resets in (min)")
                    Spacer()
                    TextField("110", text: $resetMin)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .frame(width: 64).focused($focus, equals: .resetMin)
                }
                HStack {
                    Button("Calibrate reset time") { calibrateReset() }
                    Spacer()
                    if let resetMsg { Text(resetMsg).font(.caption).foregroundStyle(.secondary) }
                }

                Divider()
                HStack(spacing: 4) {
                    Text("Weekly resets in")
                    Spacer()
                    unitField($weeklyResetDay, "3", focus: .weeklyResetDay); unit("d")
                    unitField($weeklyResetHour, "0", focus: .weeklyResetHour); unit("h")
                    unitField($weeklyResetMin, "0", focus: .weeklyResetMin); unit("m")
                }
                HStack {
                    Button("Calibrate weekly reset") { calibrateWeeklyReset() }
                    Spacer()
                    if let weeklyResetMsg { Text(weeklyResetMsg).font(.caption).foregroundStyle(.secondary) }
                }
                caption("The weekly limit is a fixed 7-day window that resets to zero — enter the \"resets in\" Claude shows so the countdown and weekly bar line up.")
            } header: { Text("Match the Claude app") }

            // MARK: Billing
            Section {
                decimalRow("Subscription paid ($)", value: $metrics.monthlyPrice, focus: .price)
                decimalRow("Usage credits spent ($)", value: $metrics.creditSpent, focus: .creditSpent)
                decimalRow("Monthly spend limit ($)", value: $metrics.creditLimit, focus: .creditLimit)
                decimalRow("Credit balance ($)", value: $metrics.creditBalance, focus: .creditBalance)
                LabeledContent("API value this cycle", value: Format.currency(metrics.cycle.costUSD))
                let totalPaid = metrics.monthlyPrice + metrics.creditSpent
                if totalPaid > 0 {
                    LabeledContent("Value ratio",
                                   value: "\(Int((metrics.cycle.costUSD / totalPaid).rounded()))× what you paid")
                }
                caption("Usage-credit figures (spent / limit / balance) are server-side — copy them from Claude → Settings → Usage credits. They show minimally on the widget once entered.")
            } header: { Text("Billing this cycle") }

            // MARK: Appearance
            Section {
                HStack {
                    Text("Widget size")
                    Slider(value: $metrics.widgetScale, in: 0.8...1.8, step: 0.05)
                        .onChange(of: metrics.widgetScale) { persist() }
                    Text("\(Int((metrics.widgetScale * 100).rounded()))%")
                        .monospacedDigit().frame(width: 46, alignment: .trailing)
                }
                Toggle("Include subagent usage", isOn: $metrics.includeSubagents)
                    .onChange(of: metrics.includeSubagents) { persist() }
                Toggle("Keep on top of other windows", isOn: $metrics.keepOnTop)
                    .onChange(of: metrics.keepOnTop) { persist() }
                Toggle("Show on all Spaces (can cover fullscreen)", isOn: $metrics.showOnAllSpaces)
                    .onChange(of: metrics.showOnAllSpaces) { persist() }
                Toggle("Launch at login", isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in
                        loginMessage = LoginItem.setEnabled(on); loginOn = LoginItem.isEnabled
                    }
                caption(loginMessage ?? "Login item: \(LoginItem.statusDescription)")
                Button("Reset widget size") { metrics.widgetScale = 1; persist() }
            } header: { Text("Appearance") }

            // MARK: Footer
            Section {
                HStack {
                    Text("ClaudePet 0.1.0").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit ClaudePet") { NSApplication.shared.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 600)
        .onAppear {
            // Field editor attaches once the window is key; defer to next runloop.
            DispatchQueue.main.async { focus = .session }
        }
    }

    // MARK: - Row builders

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A small trailing-aligned number field for the d/h/m reset inputs.
    private func unitField(_ text: Binding<String>, _ placeholder: String, focus field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 40)
            .focused($focus, equals: field)
    }

    private func unit(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary)
    }

    private func pctRow(_ label: String, text: Binding<String>, focus field: Field) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($focus, equals: field)
            Text("%").foregroundStyle(.secondary)
        }
    }

    private func numberRow(_ label: String, value: Binding<Int>, focus field: Field) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 130)
                .focused($focus, equals: field)
                .onChange(of: value.wrappedValue) { persist() }
        }
    }

    private func decimalRow(_ label: String, value: Binding<Double>, focus field: Field) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .focused($focus, equals: field)
                .onChange(of: value.wrappedValue) { persist() }
        }
    }

    private func budgetText(_ tokens: Int, _ cost: Double) -> String {
        metricsEnv.budgetUnit == .tokens ? Format.tokens(tokens) : Format.currency(cost)
    }

    // MARK: - Actions

    private func persist() { metricsEnv.saveConfigAndRecompute() }

    private func calibrate() {
        let unit = metricsEnv.budgetUnit
        var did = false
        if let sp = Double(sessionPct), sp > 0 {
            let budget = metricsEnv.blockValue(unit: unit) / (sp / 100)
            if unit == .tokens { metricsEnv.tokenBudget = Int(budget) } else { metricsEnv.costBudget = budget }
            did = true
        }
        if let wp = Double(weeklyPct), wp > 0 {
            let budget = metricsEnv.weeklyValue(unit: unit) / (wp / 100)
            if unit == .tokens { metricsEnv.weeklyTokenBudget = Int(budget) } else { metricsEnv.weeklyCostBudget = budget }
            did = true
        }
        if did {
            metricsEnv.autoBudgetFromPlan = false
            persist()
            calibrateMsg = "Calibrated ✓"
        } else {
            calibrateMsg = "Enter a % first"
        }
    }

    /// Shift the session window so its "resets in" matches the Claude app.
    private func calibrateReset() {
        guard let minutes = Double(resetMin), minutes > 0, let block = metricsEnv.activeBlock else {
            resetMsg = "Enter minutes (session must be active)"
            return
        }
        let target = Date().addingTimeInterval(minutes * 60)
        metricsEnv.sessionResetOffset += target.timeIntervalSince(block.endsAt)
        persist()
        resetMsg = "Reset calibrated ✓"
    }

    /// Shift the weekly window so its "resets in" (days + hours + minutes) matches the Claude app.
    private func calibrateWeeklyReset() {
        let d = Double(weeklyResetDay) ?? 0
        let h = Double(weeklyResetHour) ?? 0
        let m = Double(weeklyResetMin) ?? 0
        let total = d * 86_400 + h * 3_600 + m * 60
        guard total > 0, total <= WeeklyWindowEngine.weekDuration else {
            weeklyResetMsg = "Enter up to 7d"
            return
        }
        let now = Date()
        let target = now.addingTimeInterval(total)
        let current = WeeklyWindowEngine.window(anchor: metricsEnv.weeklyAnchor, now: now)
        metricsEnv.weeklyResetOffset += target.timeIntervalSince(current.end)
        persist()
        weeklyResetMsg = "Weekly reset calibrated ✓"
    }
}
