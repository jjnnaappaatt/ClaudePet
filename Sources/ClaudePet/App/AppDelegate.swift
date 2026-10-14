import AppKit
import SwiftUI
import ClaudePetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: WindowController?
    private var occlusionObserver: NSObjectProtocol?
    let metrics = MetricsStore()
    let panelVisibility = PanelVisibility()
    let resizeController = ResizeController()
    private lazy var settingsWC = SettingsWindowController(metrics: metrics)
    private lazy var dashboardWC = DashboardWindowController(metrics: metrics)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug-only: render the 1024px app-icon master (transparent margins).
        if let iconPath = ProcessInfo.processInfo.environment["CLAUDEPET_ICON"] {
            let r = ImageRenderer(content: AppIconView())
            r.scale = 1
            r.isOpaque = false
            if let cg = r.cgImage,
               let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: iconPath))
                FileHandle.standardError.write(Data("icon: wrote \(iconPath)\n".utf8))
            }
            NSApp.terminate(nil)
            return
        }

        // Debug-only: render the Settings view.
        if let settingsPath = ProcessInfo.processInfo.environment["CLAUDEPET_SETTINGS"] {
            Snapshot.render(SettingsView().environment(metrics), to: settingsPath)
            NSApp.terminate(nil)
            return
        }

        // Debug-only: render the dashboard. Unlike the other snapshots this one needs an explicit
        // size — `ImageRenderer` renders at the view's intrinsic size, and `DashboardView` is
        // layout-driven (it takes its size from the window), so with no frame there'd be nothing to
        // lay out against. `CLAUDEPET_DASHSIZE=WxH` overrides the default; check the minimum too.
        if let dashPath = ProcessInfo.processInfo.environment["CLAUDEPET_DASHBOARD"] {
            if ProcessInfo.processInfo.environment["CLAUDEPET_REAL"] != nil {
                metrics.loadFromDisk()
            } else {
                metrics.loadSampleForPreview()
            }
            applyUtilOverride()      // so gauge colours/states can be forced here too, not just in the widget
            applyCodexOverride()
            applyStatsAgeOverride()
            var size = CGSize(width: 1728, height: 1117)
            if let raw = ProcessInfo.processInfo.environment["CLAUDEPET_DASHSIZE"] {
                let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
            }
            // The /stats figures can't be eyeballed from the PNG alone (is 140.5M the bare cache or the
            // cache plus today?), so state them.
            let statsLine = "stats: total=\(metrics.statsTotalTokens().map(String.init) ?? "nil") "
                + "cacheTotal=\(metrics.statsCache?.totalWorkTokens.description ?? "nil") "
                + "filledDays=\(metrics.statsFilledDays()) dated=\(metrics.statsIsDated()) "
                + "asOf=\(metrics.statsAsOfDescription ?? "nil") todayWork=\(metrics.today.workTokens)\n"
            FileHandle.standardError.write(Data(statsLine.utf8))

            // Scale 1 by default so the PNG's pixels map 1:1 to the layout's points — every
            // measurement script here reads coordinates straight off the render, and a 2x image would
            // silently double every figure they report. `CLAUDEPET_DASHSCALE=2` opts into a retina
            // capture for documentation, where crispness matters and nothing is being measured.
            let dashScale: CGFloat = ProcessInfo.processInfo.environment["CLAUDEPET_DASHSCALE"]
                .flatMap { Double($0) }.map { CGFloat($0) } ?? 1
            Snapshot.render(DashboardView()
                                .environment(metrics)
                                .frame(width: size.width, height: size.height),
                            to: dashPath, scale: dashScale)
            NSApp.terminate(nil)
            return
        }

        // Debug-only: render all mascot frames large for visual inspection.
        if let mascotPath = ProcessInfo.processInfo.environment["CLAUDEPET_MASCOT"] {
            Snapshot.render(MascotPreviewSheet(), to: mascotPath)
            NSApp.terminate(nil)
            return
        }

        // Permission-free UI verification: render the real view to a PNG and exit.
        if let snapPath = ProcessInfo.processInfo.environment["CLAUDEPET_SNAPSHOT"] {
            if ProcessInfo.processInfo.environment["CLAUDEPET_REAL"] != nil {
                metrics.loadFromDisk()       // real ~/.claude data
            } else {
                metrics.loadSampleForPreview()
            }
            if let s = ProcessInfo.processInfo.environment["CLAUDEPET_SCALE"], let v = Double(s) {
                metrics.widgetScale = v
            }
            if let lay = ProcessInfo.processInfo.environment["CLAUDEPET_LAYOUT"],
               let l = WidgetLayout(rawValue: lay) {
                metrics.widgetLayout = l       // verification override; leaves the user's saved choice untouched
            }
            if let basis = ProcessInfo.processInfo.environment["CLAUDEPET_BASIS"],
               let b = TokenBasis(rawValue: basis) {
                metrics.tokenBasis = b         // ditto — lets a snapshot show work vs total side by side
            }
            applyUtilOverride()
            applyCodexOverride()
            applyStatsAgeOverride()
            Snapshot.render(ContentView().environment(metrics).environment(panelVisibility), to: snapPath)
            NSApp.terminate(nil)
            return
        }

        // Dockless agent app: no Dock icon, no app menu, but panels still show.
        NSApp.setActivationPolicy(.accessory)

        let root = ContentView()
            .environment(metrics)
            .environment(panelVisibility)
            .environment(resizeController)
        let hosting = FittingHostingView(rootView: root)
        hosting.sizingOptions = .intrinsicContentSize   // report SwiftUI's fitting size

        let wc = WindowController(content: hosting)
        // Follow the content. The fit inside `WindowController.init` runs before the first scan, so
        // without this the panel keeps its near-empty launch height — see `FittingHostingView`.
        hosting.onIntrinsicSizeChange = { [weak wc] in wc?.refitToContent() }
        wc.panel.setOnTop(metrics.keepOnTop)
        wc.panel.setShowOnAllSpaces(metrics.showOnAllSpaces)
        wc.show()
        windowController = wc
        resizeController.window = wc
        resizeController.store = metrics

        // Resize the panel to fit + apply window settings when config changes.
        metrics.onConfigChange = { [weak wc, weak metrics] in
            DispatchQueue.main.async {
                wc?.fitToContent()
                if let m = metrics {
                    wc?.panel.setOnTop(m.keepOnTop)
                    wc?.panel.setShowOnAllSpaces(m.showOnAllSpaces)
                }
            }
        }

        // Open Settings in a real key-capable window when the gear is tapped.
        NotificationCenter.default.addObserver(forName: .openClaudePetSettings,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsWC.show() }
        }

        // Open the expanded dashboard when the widget's expand button is tapped. It needs the panel
        // so it can hide the widget while full screen (else "Show on all Spaces" floats the widget
        // over its own dashboard).
        dashboardWC.widgetPanel = wc.panel
        NotificationCenter.default.addObserver(forName: .openClaudePetDashboard,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dashboardWC.show() }
        }

        // Pause the mascot when the panel is fully occluded (bitfield: use .contains).
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: wc.panel, queue: .main
        ) { [weak panelVisibility] note in
            guard let win = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                panelVisibility?.isVisible = win.occlusionState.contains(.visible)
            }
        }

        // Verification-only heartbeat: write metrics to a file on each recompute.
        if let hb = ProcessInfo.processInfo.environment["CLAUDEPET_HEARTBEAT"] {
            metrics.onRecompute = { [weak metrics] in
                guard let m = metrics else { return }
                let obj: [String: Any] = [
                    "lastUpdated": m.lastUpdated?.timeIntervalSince1970 ?? 0,
                    "todayWork": m.today.workTokens,
                    "todayTotal": m.today.totalTokens,
                    // The Auto budgets and which denominator produced them — the only way to check
                    // these against real data without a screenshot, since Settings isn't on screen.
                    "sessionBudget": m.blockBudget(unit: m.budgetUnit),
                    "weeklyBudget": m.weeklyBudget(unit: m.budgetUnit),
                    "budgetBasis": m.budgetBasisDescription,
                    // Our own 5h window, so its alignment against Claude's `resets_at` is checkable.
                    "blockStart": m.activeBlock?.start.timeIntervalSince1970 ?? 0,
                    "blockEnd": m.activeBlock?.endsAt.timeIntervalSince1970 ?? 0,
                    // The pace baselines, for the same reason as the budgets above: they're a
                    // rolling 30-day mean that no other surface prints, and the caption deliberately
                    // doesn't name its span, so this file is the only way to check them against a
                    // direct scan of the transcripts.
                    "dailyAverage": m.dailyAverage(unit: m.budgetUnit),
                    "subagentDailyAverage": m.subagentDailyAverage(unit: m.budgetUnit),
                    "allTimeDailyCount": m.allTimeDaily.count,
                    "allTimeDailyFirst": m.allTimeDaily.first?.date.timeIntervalSince1970 ?? 0,
                    "allTimeDailyLast": m.allTimeDaily.last?.date.timeIntervalSince1970 ?? 0,
                ]
                if let d = try? JSONSerialization.data(withJSONObject: obj) {
                    try? d.write(to: URL(fileURLWithPath: hb))
                }
            }
        }

        // Verification override; leaves the user's saved choice untouched (nothing persists unless
        // they change a setting). Forces the local-history budget estimate so it can be checked
        // without the statusline's numbers standing in front of it.
        if ProcessInfo.processInfo.environment["CLAUDEPET_NOLIVE"] != nil {
            metrics.useStatuslineData = false
            metrics.clearCalibrationForTesting()   // else the last synced budgets still win
        }

        metrics.start()

        // Debug: the panel-sizing path. `CLAUDEPET_SNAPSHOT` cannot see this — `ImageRenderer` draws
        // the content at its own ideal size and never asks the panel — which is how a panel fitted
        // once to near-empty launch content (427pt) shipped against a 611pt widget, clipping the
        // header and footer. Waits for the first scan, then reports whether the panel followed.
        if ProcessInfo.processInfo.environment["CLAUDEPET_PANELFIT"] != nil {
            func log(_ s: String) { FileHandle.standardError.write(Data("diag: \(s)\n".utf8)) }
            let t0 = Date()
            func line(_ tag: String) -> String {
                String(format: "%@ t=%.1fs content=%.0f panel=%.0f", tag, Date().timeIntervalSince(t0),
                       hosting.fittingSize.height, wc.panel.frame.height)
            }
            log(line("launch "))
            var dataSeenAt: Date?
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if dataSeenAt == nil, !self.metrics.todayByModel.isEmpty { dataSeenAt = Date() }
                    let settled = dataSeenAt.map { Date().timeIntervalSince($0) > 1.5 } ?? false
                    guard settled || Date().timeIntervalSince(t0) > 180 else { return }
                    timer.invalidate()
                    let gap = hosting.fittingSize.height - wc.panel.frame.height
                    log(line(settled ? "settled" : "TIMEOUT (no scan data)"))
                    log(abs(gap) < 1 ? "OK: panel follows its content"
                                     : String(format: "FAIL: panel is %.0fpt off its content", gap))
                    NSApp.terminate(nil)
                }
            }
        }

        // Debug: simulate the REAL flow for the dashboard — accessory app already running, then the
        // expand button is tapped. Reports the things that silently break instead of erroring:
        // whether the window can actually go full screen, whether ⌃⌘F is wired (SwiftUI ships an
        // EMPTY View menu, so it isn't unless we add the item), and whether the widget gets out of
        // the way and comes back.
        if ProcessInfo.processInfo.environment["CLAUDEPET_OPENDASHBOARD"] != nil {
            func log(_ s: String) { FileHandle.standardError.write(Data("diag: \(s)\n".utf8)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NotificationCenter.default.post(name: .openClaudePetDashboard, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard let win = NSApp.windows.first(where: { $0.title == "ClaudePet" }) else {
                        log("FAIL: no dashboard window"); NSApp.terminate(nil); return
                    }
                    let sm = win.styleMask
                    log("policy=\(NSApp.activationPolicy().rawValue) key=\(win.isKeyWindow) "
                        + "titled=\(sm.contains(.titled)) resizable=\(sm.contains(.resizable)) "
                        + "fullScreenPrimary=\(win.collectionBehavior.contains(.fullScreenPrimary)) "
                        + "contentMinSize=\(Int(win.contentMinSize.width))x\(Int(win.contentMinSize.height)) "
                        + "minSize=\(Int(win.minSize.width))x\(Int(win.minSize.height))")
                    let fs = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items
                        .first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
                    log("fullScreenMenuItem=\(fs.map { "\"\($0.title)\" ⌃⌘\($0.keyEquivalent)" } ?? "MISSING")")
                    log("widgetVisibleBefore=\(wc.panel.isVisible)")

                    let nc = NotificationCenter.default
                    nc.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                   object: win, queue: .main) { _ in
                        MainActor.assumeIsolated {
                            log("entered fullScreen=\(win.styleMask.contains(.fullScreen)) "
                                + "size=\(Int(win.frame.width))x\(Int(win.frame.height)) "
                                + "widgetHidden=\(!wc.panel.isVisible)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                win.toggleFullScreen(nil)
                            }
                        }
                    }
                    nc.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                   object: win, queue: .main) { _ in
                        MainActor.assumeIsolated {
                            log("exited widgetRestored=\(wc.panel.isVisible)")
                            win.close()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                log("afterClose policy=\(NSApp.activationPolicy().rawValue) "
                                    + "(0 = regular, 1 = dockless accessory)")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                    win.toggleFullScreen(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                log("TIMEOUT"); NSApp.terminate(nil)
            }
        }

        // Debug: simulate the REAL flow — app already running as accessory, then open
        // Settings (as if the gear was clicked) and report activation/key/responder state.
        if ProcessInfo.processInfo.environment["CLAUDEPET_OPENSETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NotificationCenter.default.post(name: .openClaudePetSettings, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let key = NSApp.keyWindow
                    let frName = key?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    let msg = "diag: active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) " +
                              "keyWindow=\(key?.title ?? "nil") isKey=\(key?.isKeyWindow ?? false) " +
                              "firstResponder=\(frName)\n"
                    FileHandle.standardError.write(Data(msg.utf8))
                }
            }
        }
    }

    /// Debug-only: force the gauges (and so the weather, mood, and bar colours) by faking the
    /// statusline utilization. Accepts one value ("61", drives 5h) or "five,seven" ("96,88").
    ///
    /// Shared by the widget and dashboard snapshot paths — it lived only in the widget's, which meant
    /// `CLAUDEPET_UTIL` was silently ignored when checking the dashboard and two renders that should
    /// have differed came out identical.
    private func applyUtilOverride() {
        guard let u = ProcessInfo.processInfo.environment["CLAUDEPET_UTIL"] else { return }
        let parts = u.split(separator: ",").compactMap { Double($0) }
        let five = parts.first ?? 0
        let seven = parts.count > 1 ? parts[1] : 0
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reset = f.string(from: Date().addingTimeInterval(2 * 3600))
        let json = "{\"five_hour\":{\"utilization\":\(five),\"resets_at\":\"\(reset)\"},\"seven_day\":{\"utilization\":\(seven),\"resets_at\":\"\(reset)\"}}"
        let path = NSTemporaryDirectory() + "cp-snap-util.json"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        metrics.useStatuslineData = true
        metrics.statuslineCachePath = path
        metrics.recompute()
    }

    /// Debug-only: force the Codex row by faking its cache. `CLAUDEPET_CODEX=<pct>[,<age_seconds>]`
    /// — "47" is a live 47%, "47,90000" is the same figure gone stale past a day.
    /// `CLAUDEPET_CODEX=none` writes no file at all, which is how a machine without Codex renders.
    ///
    /// It writes to its **own** temp file. Never point this at
    /// `/tmp/claude/codex-usage-cache.tsv` — that is the live file the terminal statusline reads,
    /// and a snapshot run would leave a fake percentage on the user's real status bar.
    /// `CLAUDEPET_STATSAGE=<days>` re-dates a **copy** of the `/stats` cache, so both freshness states
    /// of the "Total tokens" headline can be looked at instead of reasoned about.
    ///
    /// Neither occurs on demand: `+Nd` needs Claude Code to be a few days behind, and the dated
    /// `to 4 Aug` chip needs it behind by more than the local history reaches — months of never running
    /// `/stats`, by which point transcript cleanup has removed the days that would fill the gap. The
    /// chip is the whole point of the feature, and a state that can't be rendered can't be checked.
    ///
    /// Pair with `CLAUDEPET_REAL=1`: sample mode builds its own frozen `statsCache`, and the
    /// `recompute()` below would overwrite it (along with every other sample aggregate). Writes its own
    /// temp file — `~/.claude/stats-cache.json` is Claude Code's, and nothing here may write to it.
    private func applyStatsAgeOverride() {
        guard let raw = ProcessInfo.processInfo.environment["CLAUDEPET_STATSAGE"],
              let days = Int(raw),
              let data = FileManager.default.contents(atPath: metrics.statsCachePath),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        var g = Calendar(identifier: .gregorian)
        g.timeZone = .current
        guard let back = g.date(byAdding: .day, value: -days, to: Date()) else { return }
        let c = g.dateComponents([.year, .month, .day], from: back)
        guard let y = c.year, let m = c.month, let d = c.day else { return }
        obj["lastComputedDate"] = String(format: "%04d-%02d-%02d", y, m, d)
        let path = NSTemporaryDirectory() + "cp-snap-stats.json"
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? out.write(to: URL(fileURLWithPath: path))
        metrics.statsCachePath = path
        metrics.recompute()
    }

    private func applyCodexOverride() {
        guard let raw = ProcessInfo.processInfo.environment["CLAUDEPET_CODEX"] else { return }
        let path = NSTemporaryDirectory() + "cp-snap-codex.tsv"
        try? FileManager.default.removeItem(atPath: path)
        if raw != "none" {
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            let pct = parts.first ?? 0
            let age = parts.count > 1 ? parts[1] : 0
            let reset = Int(Date().addingTimeInterval(7 * 86_400).timeIntervalSince1970)
            let recorded = Int(Date().addingTimeInterval(-age).timeIntervalSince1970)
            // A third component fakes the token count; omit it for the four-field cache an older
            // statusline writes, which is a state worth being able to look at.
            let tokens = parts.count > 2 ? "\t\(Int(parts[2]))" : "\t21682073"
            try? "10080\t\(pct)\t\(reset)\t\(recorded)\(tokens)\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        metrics.codexUsageCachePath = path
        metrics.recompute()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        metrics.stop()
    }
}
