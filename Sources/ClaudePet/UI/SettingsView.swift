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

    private enum Field { case session, weekly, resetMin, sessionBudget, weeklyBudget, price, creditSpent, creditLimit, creditBalance, billingDay }

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
                    // Two genuinely different denominators hide behind "Auto" and they differ by
                    // several ×, so each budget states its own — a single shared sentence used to
                    // call a synced weekly budget an "estimate".
                    caption("5-hour: \(metrics.budgetBasisDescription(for: .block)).\nWeekly: \(metrics.budgetBasisDescription(for: .weekly)).")
                    caption("A budget synced from Claude's percentages keeps its value until a better reading replaces it — a window resetting doesn't expire it, because your limit isn't what reset. Without one, the fallback is a rough upper bound built from your own heaviest completed windows, which measured ~3× above Claude's real 5-hour limit. Turn off \"Use Claude's live usage\" below to force that fallback.")
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
                caption("Manual fallback: open Claude → Settings → Usage and enter the % shown, then Calibrate — used when live data isn't available. With live data on, the budgets and the two reset times below keep themselves in sync and you shouldn't need this.")
                pctRow("Current session", text: $sessionPct, focus: .session)
                pctRow("Weekly (all models)", text: $weeklyPct, focus: .weekly)
                HStack {
                    Button("Calibrate budgets") { calibrate() }
                    Spacer()
                    if let calibrateMsg { Text(calibrateMsg).font(.caption).foregroundStyle(.secondary) }
                }
                if let age = metrics.calibrationAgeDescription {
                    // No "a window reset since — re-calibrate" nag any more: a fitted budget
                    // outlives the window it was measured in, so nothing needs re-aligning.
                    caption("Last calibrated \(age). Budgets hold until a reading at least as precise replaces them.")
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

                Divider()
                Toggle("Override billing cycle day", isOn: billingDayOverrideEnabled)
                if metrics.billingCycleDayOverride != nil {
                    numberRow("Billing cycle day (1–31)", value: billingDayOverrideValue, focus: .billingDay)
                }
                caption("ClaudePet guesses the billing-cycle day from your subscription date, but on team/org plans that can differ from the org's real invoice day. If the Cycle countdown doesn't match Claude → Settings → Billing → Invoices, override it here with the day-of-month your invoices actually land on.")
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
                Picker("Count tokens as", selection: $metrics.tokenBasis) {
                    Text("Work").tag(TokenBasis.work)
                    Text("Total").tag(TokenBasis.total)
                }
                .pickerStyle(.segmented)
                .onChange(of: metrics.tokenBasis) { persist() }
                caption("Work = input + output. Total also counts cache reads & writes — far larger (often 100–300×), and what Claude actually processes. Every token figure follows this: the header, charts, daily pace, per-model split, Week/cycle counts and the \"used this window/week\" line under each gauge. Cost ($) always includes cache.")
                HStack {
                    Text("Widget size")
                    Slider(value: $metrics.widgetScale, in: 0.8...1.8, step: 0.05)
                        .onChange(of: metrics.widgetScale) { persist() }
                    Text("\(Int((metrics.widgetScale * 100).rounded()))%")
                        .monospacedDigit().frame(width: 46, alignment: .trailing)
                }
                Toggle("Weather effects", isOn: $metrics.weatherEffectsEnabled)
                    .onChange(of: metrics.weatherEffectsEnabled) { persist() }
                caption("Ambient sky behind the pet — sun, clouds, rain and the odd celebration, reacting to your usage.")
                Toggle("Include subagent usage", isOn: $metrics.includeSubagents)
                    .onChange(of: metrics.includeSubagents) { persist() }
                caption("Counts turns run by the Task tool (the subagents/ transcripts under ~/.claude) — often a large share of your turns. Their share is BIGGER under 'Work' than under 'Total', not smaller: a subagent runs in a short-lived context, while the main conversation re-reads a large cached one every turn, so cache tokens pile up faster on the main thread. Measured on real usage: 15% of work but 8% of cache-inclusive total. While Claude's live usage drives the gauges, turning this off changes the token counts but NOT the two bar percentages — those are Claude's own accounting, which always includes subagents.")
                Toggle("Count repeated log lines (match /stats)", isOn: $metrics.countRepeatedLogLines)
                    .onChange(of: metrics.countRepeatedLogLines) { persist() }
                caption("Claude Code writes the same assistant turn to its transcript several times — about 57% of logged lines repeat a message id already seen, with byte-identical usage. ClaudePet counts each turn once; Claude Code's /stats counts the lines, which is why it reports roughly 2.4× as many tokens. Turn this on to match /stats. It doesn't find missing usage — it counts one API response more than once — so leave it off unless you're reconciling the two.")
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

    /// Whether the manual billing-cycle-day override is on. Turning it on seeds today's
    /// day-of-month as a starting guess; turning it off clears the override (nil = auto).
    private var billingDayOverrideEnabled: Binding<Bool> {
        Binding(
            get: { metricsEnv.billingCycleDayOverride != nil },
            set: { on in
                metricsEnv.billingCycleDayOverride = on
                    ? (metricsEnv.billingCycleDayOverride ?? Calendar.current.component(.day, from: Date()))
                    : nil
                persist()
            }
        )
    }

    /// The override day (1–31) as a plain `Int` binding for `numberRow`, defaulting to 1 while off.
    /// `numberRow` already persists on change, so this setter only clamps.
    private var billingDayOverrideValue: Binding<Int> {
        Binding(
            get: { metricsEnv.billingCycleDayOverride ?? 1 },
            set: { metricsEnv.billingCycleDayOverride = max(1, min(31, $0)) }
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
