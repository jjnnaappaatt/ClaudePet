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
    @State private var calibrateMsg: String?
    @State private var resetMsg: String?
    @FocusState private var focus: Field?

    private enum Field { case session, weekly, resetMin, sessionBudget, weeklyBudget, price, creditSpent, creditLimit, creditBalance }

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

                Picker("Budget source", selection: budgetSourceBinding) {
                    Text("Auto").tag(MetricsStore.BudgetSource.auto)
                    Text("Plan").tag(MetricsStore.BudgetSource.plan)
                    Text("Custom").tag(MetricsStore.BudgetSource.custom)
                }
                .pickerStyle(.segmented)

                switch metrics.budgetSource {
                case .auto:
                    LabeledContent("Session budget", value: amount(metrics.blockBudget(unit: metrics.budgetUnit)))
                    LabeledContent("Weekly budget", value: amount(metrics.weeklyBudget(unit: metrics.budgetUnit)))
                    caption("Auto-sized from your heaviest completed 5-hour and weekly usage so far, +\(Int((metrics.peakHeadroom * 100).rounded()))% headroom — the gauges fill as you approach your own record and rise when you set a new one. This tracks YOUR usage, not Anthropic's cap. To anchor it to Claude's exact %, use Calibrate below (that override lasts until the next reset).")
                case .plan:
                    LabeledContent("Session budget", value: budgetText(metrics.plan.tokenBudget, metrics.plan.costBudget))
                    LabeledContent("Weekly budget", value: budgetText(metrics.plan.weeklyTokenBudget, metrics.plan.weeklyCostBudget))
                    caption("Anthropic doesn't publish exact caps — these are tier-scaled estimates.")
                case .custom:
                    if metrics.budgetUnit == .tokens {
                        numberRow("Session budget", value: $metrics.tokenBudget, focus: .sessionBudget)
                        numberRow("Weekly budget", value: $metrics.weeklyTokenBudget, focus: .weeklyBudget)
                    } else {
                        decimalRow("Session budget ($)", value: $metrics.costBudget, focus: .sessionBudget)
                        decimalRow("Weekly budget ($)", value: $metrics.weeklyCostBudget, focus: .weeklyBudget)
                    }
                }
            } header: { Text("5-hour & weekly budget") }

            // MARK: Calibration
            Section {
                Toggle("Use Claude's live usage (from statusline)", isOn: $metrics.useStatuslineData)
                    .onChange(of: metrics.useStatuslineData) { persist() }
                if metrics.useStatuslineData {
                    if metrics.serverDriven5h || metrics.serverDriven7d {
                        caption("Live data found\(metrics.serverDataAge.map { " (as of \($0))" } ?? "") — the 5h & weekly gauges show Claude's real numbers. ClaudePet reads only the statusline's local cache file; it never touches your token or the network.")
                    } else {
                        caption("No live data yet. Install & run claude-statusline (it writes a local cache); the gauges then switch to Claude's real numbers. Until then they use the estimate below. ClaudePet never reads your token or makes network calls.")
                    }
                }
                Divider()
                caption("Manual fallback: open Claude → Settings → Usage and enter the % shown, then Calibrate — used when live data isn't available.")
                pctRow("Current session", text: $sessionPct, focus: .session)
                pctRow("Weekly (all models)", text: $weeklyPct, focus: .weekly)
                HStack {
                    Button("Calibrate budgets") { calibrate() }
                    Spacer()
                    if let calibrateMsg { Text(calibrateMsg).font(.caption).foregroundStyle(.secondary) }
                }
                if let age = metrics.calibrationAgeDescription {
                    caption("Last calibrated \(age)." + (metrics.calibrationIsStale
                        ? " A limit reset since — re-calibrate to re-align the gauges." : ""))
                } else {
                    caption("Not calibrated yet — the gauges are tier-scaled estimates until you do.")
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
                Picker("Weekly reset day", selection: $metrics.weeklyResetWeekday) {
                    Text("Sunday").tag(1)
                    Text("Monday").tag(2)
                    Text("Tuesday").tag(3)
                    Text("Wednesday").tag(4)
                    Text("Thursday").tag(5)
                    Text("Friday").tag(6)
                    Text("Saturday").tag(7)
                }
                .onChange(of: metrics.weeklyResetWeekday) { persist() }
                DatePicker("Weekly reset time", selection: weeklyResetTime, displayedComponents: .hourAndMinute)
                caption("The weekly limit is a fixed 7-day window that resets to zero on this day & time (default Monday 3:00 PM) — set it to match the Claude app so the countdown and weekly bar line up.")
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
                caption("Every '$' figure is a notional API-equivalent estimate from the pricing table — on a subscription you don't pay per token; it shows the value you're getting, not a bill. Token counts, by contrast, are exact (read from Claude's transcripts).")
                caption("Usage-credit figures (spent / limit / balance) are server-side — copy them from Claude → Settings → Usage credits. They show minimally on the widget once entered.")
            } header: { Text("Billing this cycle") }

            // MARK: Appearance
            Section {
                Picker("Widget layout", selection: $metrics.widgetLayout) {
                    Text("Wide").tag(WidgetLayout.landscape)
                    Text("Tall").tag(WidgetLayout.vertical)
                }
                .pickerStyle(.segmented)
                .onChange(of: metrics.widgetLayout) { persist() }
                caption("Wide = the two-column landscape card; Tall = the original single column.")
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
                    Text("ClaudePet \(ClaudePetCore.version)").font(.caption).foregroundStyle(.secondary)
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

    /// Reads/writes the weekly reset time-of-day (hour + minute) as a `Date` for `DatePicker`.
    private var weeklyResetTime: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = metricsEnv.weeklyResetHour
                c.minute = metricsEnv.weeklyResetMinute
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                metricsEnv.weeklyResetHour = c.hour ?? 15
                metricsEnv.weeklyResetMinute = c.minute ?? 0
                persist()
            }
        )
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

    /// Formats a live budget value in the current gauge unit.
    private func amount(_ v: Double) -> String {
        metricsEnv.budgetUnit == .tokens ? Format.tokens(Int(v)) : Format.currency(v)
    }

    /// Picker binding that persists on change (avoids onChange on a computed property).
    private var budgetSourceBinding: Binding<MetricsStore.BudgetSource> {
        Binding(get: { metricsEnv.budgetSource },
                set: { metricsEnv.budgetSource = $0; persist() })
    }

    // MARK: - Actions

    private func persist() { metricsEnv.saveConfigAndRecompute() }

    private func calibrate() {
        // Back-solve lives in MetricsStore (single source) so the gauges and tests agree.
        let did = metricsEnv.calibrateLimits(
            sessionPct: Double(sessionPct) ?? 0,
            weeklyPct: Double(weeklyPct) ?? 0,
            unit: metricsEnv.budgetUnit)
        calibrateMsg = did ? "Calibrated ✓" : "Enter a % (with usage logged) first"
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
}
