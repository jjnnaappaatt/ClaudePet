import Testing
import Foundation
@testable import ClaudePetCore

/// The two aggregates the dashboard adds: the billing cycle broken down by date and by project.
///
/// Both are computed with the SAME in-cycle predicate as `cycle` itself, because the dashboard shows
/// all three together — a bar chart or a project list that didn't add up to the headline figure would
/// read as a bug. Most of these tests exist to hold that invariant.
@Suite struct ProjectAndCycleTests {

    let pricing = PricingTable.default

    /// Fixed calendar + instants: anything reading `Date()`/`Calendar.current` unpinned can pass or
    /// fail by when the suite runs, which has already caused a real flaky failure in this repo.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// A cycle anchored mid-day, like a real subscription anniversary (`03:03:51Z`) — so the first
    /// and last calendar dates it touches are only partly inside it.
    private var cycle: (start: Date, end: Date) { (at(2026, 6, 16, 3, 3), at(2026, 7, 16, 3, 3)) }

    // MARK: - Project identity comes off the transcript, not the directory name

    @Test func parserTakesTheProjectFromTheLinesCwd() throws {
        let line = #"""
        {"type":"assistant","timestamp":"2026-06-20T10:00:00.000Z","cwd":"/Users/napat/Desktop/LiDAR + HPE","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5}}}
        """#
        let e = try #require(JSONLParser.entry(fromLine: line))
        #expect(e.project == "/Users/napat/Desktop/LiDAR + HPE")
    }

    /// The `~/.claude/projects` directory name for that path is `-Users-napat-Desktop-LiDAR---HPE`:
    /// every non-alphanumeric becomes `-`, so spaces and the `+` are indistinguishable and the name
    /// can't be decoded back. Reading `cwd` is what keeps the label exact.
    @Test func displayNameKeepsSpacesAndPunctuationTheDirectoryNameWouldDestroy() {
        #expect(ProjectTotal(path: "/Users/napat/Desktop/LiDAR + HPE").displayName == "LiDAR + HPE")
        #expect(ProjectTotal(path: "/Users/napat/Desktop/AAI/Support Project").displayName == "Support Project")
        #expect(ProjectTotal(path: "/Users/napat/ClaudePet").displayName == "ClaudePet")
    }

    @Test func aLineWithNoCwdYieldsAnEmptyProjectShownAsADash() throws {
        // The only real transcripts lacking `cwd` are subagents/workflows/**/journal.jsonl, which
        // carry no usage — but a missing field must degrade, never crash or invent a path.
        let line = #"""
        {"type":"assistant","timestamp":"2026-06-20T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5}}}
        """#
        let e = try #require(JSONLParser.entry(fromLine: line))
        #expect(e.project == "")
        #expect(ProjectTotal(path: "").displayName == "—")
    }

    // MARK: - cycleDaily

    @Test func cycleDailyCoversEveryDateTheCycleTouchesIncludingBothPartialEnds() {
        let agg = Aggregator.compute(entries: [], pricing: pricing, now: at(2026, 7, 1),
                                     calendar: cal, cycleWindow: cycle)
        // Jun 16 … Jul 16 inclusive — 15 days left in June, 16 in July. Jul 16 counts because
        // midnight on the 16th is still before the 03:03 boundary.
        #expect(agg.cycleDaily.count == 31)
        #expect(agg.cycleDaily.first?.date == at(2026, 6, 16, 0, 0))
        #expect(agg.cycleDaily.last?.date == at(2026, 7, 16, 0, 0))
    }

    @Test func cycleDailyBarsSumExactlyToTheCycleTotal() {
        let entries = [
            TestSupport.entry(at: at(2026, 6, 16, 9), input: 100, output: 10),    // opening partial day
            TestSupport.entry(at: at(2026, 6, 20, 14), input: 200, output: 20),
            TestSupport.entry(at: at(2026, 7, 1, 8), input: 300, output: 30),
            TestSupport.entry(at: at(2026, 7, 16, 1), input: 400, output: 40),    // closing partial day
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 16, 2),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycleDaily.reduce(0) { $0 + $1.workTokens } == agg.cycle.workTokens)
        #expect(agg.cycleDaily.reduce(0) { $0 + $1.totalTokens } == agg.cycle.totalTokens)
        #expect(agg.cycle.workTokens == 1100)                                     // 110+220+330+440
        #expect(abs(agg.cycleDaily.reduce(0) { $0 + $1.costUSD } - agg.cycle.costUSD) < 1e-9)
    }

    /// The window is half-open on BOTH ends. An entry before the opening instant (but on the opening
    /// date) or at/after the closing instant belongs to a different cycle and must be counted in
    /// neither the headline nor the bars — previously `cycle` was unbounded above, so a
    /// clock-skewed future turn inflated the total while belonging to no bucket.
    @Test func turnsOutsideTheCycleInstantsCountTowardNeitherTheTotalNorTheBars() {
        let entries = [
            TestSupport.entry(at: at(2026, 6, 16, 2, 0), input: 999, output: 0),   // before 03:03 open
            TestSupport.entry(at: at(2026, 6, 16, 4, 0), input: 100, output: 0),   // inside
            TestSupport.entry(at: at(2026, 7, 16, 3, 3), input: 888, output: 0),   // exactly the close
            TestSupport.entry(at: at(2026, 7, 20, 12), input: 777, output: 0),     // after
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 10),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycle.workTokens == 100)
        #expect(agg.cycleDaily.reduce(0) { $0 + $1.workTokens } == 100)
        #expect(agg.cycleDaily.first?.workTokens == 100)   // the in-window turn, on the opening date
    }

    /// A midnight-aligned cycle must NOT gain a spurious empty trailing bar. This is not a contrived
    /// boundary: `AccountInfo.dayOverrideCycleBounds` zeroes hour/minute/second, so every user who
    /// sets "Override billing cycle day" gets bounds exactly on midnight. The mid-day case above
    /// can't catch a `d <= end` off-by-one, because no bucket date coincides with a 03:03 boundary.
    @Test func aMidnightAlignedCycleGainsNoEmptyTrailingBar() {
        let midnight = (start: at(2026, 6, 4, 0, 0), end: at(2026, 7, 4, 0, 0))
        let agg = Aggregator.compute(entries: [], pricing: pricing, now: at(2026, 6, 20),
                                     calendar: cal, cycleWindow: midnight)
        #expect(agg.cycleDaily.count == 30)                        // Jun 4 … Jul 3, not Jul 4
        #expect(agg.cycleDaily.last?.date == at(2026, 7, 3, 0, 0))
    }

    @Test func noCycleWindowMeansNoCycleBuckets() {
        let agg = Aggregator.compute(entries: [TestSupport.entry(at: at(2026, 7, 1), input: 10, output: 0)],
                                     pricing: pricing, now: at(2026, 7, 1), calendar: cal)
        #expect(agg.cycleDaily.isEmpty)
        #expect(agg.cycleByProject.isEmpty)
        #expect(agg.cycle.workTokens == 0)
    }

    // MARK: - cycleByProject

    @Test func cycleByProjectSumsExactlyToTheCycleTotal() {
        let entries = [
            TestSupport.entry(at: at(2026, 6, 20), input: 100, output: 0, project: "/a/one"),
            TestSupport.entry(at: at(2026, 6, 21), input: 200, output: 0, project: "/a/two"),
            TestSupport.entry(at: at(2026, 7, 1), input: 300, output: 0, project: "/a/one"),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 2),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycleByProject.reduce(0) { $0 + $1.workTokens } == agg.cycle.workTokens)
        #expect(agg.cycleByProject.reduce(0) { $0 + $1.totalTokens } == agg.cycle.totalTokens)
        #expect(abs(agg.cycleByProject.reduce(0) { $0 + $1.costUSD } - agg.cycle.costUSD) < 1e-9)
    }

    @Test func projectsStaySeparateAndTheHeaviestLeads() {
        let entries = [
            TestSupport.entry(at: at(2026, 6, 20), input: 100, output: 0, project: "/a/light"),
            TestSupport.entry(at: at(2026, 6, 21), input: 900, output: 0, project: "/a/heavy"),
            TestSupport.entry(at: at(2026, 6, 22), input: 100, output: 0, project: "/a/heavy"),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 2),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycleByProject.count == 2)
        #expect(agg.cycleByProject.first?.path == "/a/heavy")
        #expect(agg.cycleByProject.first?.workTokens == 1000)
        #expect(agg.cycleByProject.last?.workTokens == 100)
    }

    /// Everything without a recorded cwd collapses into one bucket, and it sorts LAST however heavy
    /// it is — an unattributable pile shouldn't head a list of named projects.
    @Test func turnsWithNoCwdCollapseIntoOneTrailingBucket() {
        let entries = [
            TestSupport.entry(at: at(2026, 6, 20), input: 5_000, output: 0),               // no cwd
            TestSupport.entry(at: at(2026, 6, 21), input: 5_000, output: 0),               // no cwd
            TestSupport.entry(at: at(2026, 6, 22), input: 100, output: 0, project: "/a/named"),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 2),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycleByProject.count == 2)
        #expect(agg.cycleByProject.first?.path == "/a/named")     // named leads despite being tiny
        #expect(agg.cycleByProject.last?.path == "")
        #expect(agg.cycleByProject.last?.workTokens == 10_000)    // both merged, not two buckets
    }

    // MARK: - Grouping: cwd is per-turn, the project directory is per-project

    /// The bug this design exists to prevent. On real data `cwd` took 120 distinct values across 11
    /// projects, because workflow worktrees and incidental subdirectories each get their own — so a
    /// list grouped by `cwd` read "+92 more". Grouping by the transcript's directory folds them.
    @Test func subdirectoriesAndWorktreesFoldIntoTheirProjectNotSeparateRows() {
        let dir = ProjectKey.encode("/Users/x/CLICS")
        let entries = [
            TestSupport.entry(at: at(2026, 6, 20), input: 100, output: 0,
                              project: "/Users/x/CLICS", projectDir: dir),
            TestSupport.entry(at: at(2026, 6, 20), input: 200, output: 0,
                              project: "/Users/x/CLICS/backend", projectDir: dir),
            TestSupport.entry(at: at(2026, 6, 21), input: 300, output: 0,
                              project: "/Users/x/CLICS/.claude/worktrees/wf_abc123", projectDir: dir),
            TestSupport.entry(at: at(2026, 6, 21), input: 400, output: 0,
                              project: "/Users/x/CLICS/ui/public/js", projectDir: dir),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 2),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycleByProject.count == 1)
        #expect(agg.cycleByProject.first?.path == "/Users/x/CLICS")
        #expect(agg.cycleByProject.first?.workTokens == 1000)   // 100+200+300+400, all four folded
    }

    /// Naming is by re-encoding, not by frequency. Here MOST turns ran in a subdirectory, so picking
    /// the commonest cwd would label the project "BMEiCon2026" — which is what happened to three of
    /// the eleven real projects when that approach was measured.
    @Test func theProjectIsNamedByReEncodingNotByTheCommonestCwd() {
        let root = "/Users/x/Desktop/LiDAR + HPE"
        let dir = ProjectKey.encode(root)
        #expect(dir == "-Users-x-Desktop-LiDAR---HPE")     // space, '+', space → three dashes
        var entries = [TestSupport.entry(at: at(2026, 6, 20), input: 10, output: 0,
                                         project: root, projectDir: dir)]
        for i in 0..<9 {   // the subdirectory dominates 9:1
            entries.append(TestSupport.entry(at: at(2026, 6, 21, 1 + i), input: 10, output: 0,
                                             project: root + "/BMEiCon2026", projectDir: dir))
        }
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 2),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycleByProject.count == 1)
        #expect(agg.cycleByProject.first?.path == root)
        #expect(agg.cycleByProject.first?.displayName == "LiDAR + HPE")
    }

    /// No turn ever ran in the project root, so nothing re-encodes to the directory name. Fall back
    /// to the shallowest path seen rather than to nothing or to an arbitrary deep one.
    @Test func aProjectNoTurnEverRanInFallsBackToTheShallowestPathSeen() {
        let dir = ProjectKey.encode("/Users/x/Deep")
        let entries = [
            TestSupport.entry(at: at(2026, 6, 20), input: 10, output: 0,
                              project: "/Users/x/Deep/a/b/c", projectDir: dir),
            TestSupport.entry(at: at(2026, 6, 21), input: 10, output: 0,
                              project: "/Users/x/Deep/a", projectDir: dir),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 2),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycleByProject.first?.path == "/Users/x/Deep/a")
    }

    /// Two directories can resolve to the same real project — one session opened in the root, another
    /// in a subdirectory that got its own folder. They're one project, so they get one row.
    @Test func twoDirectoriesResolvingToTheSameProjectMergeIntoOneRow() {
        let root = "/Users/x/AAI"
        let entries = [
            TestSupport.entry(at: at(2026, 6, 20), input: 100, output: 0,
                              project: root, projectDir: ProjectKey.encode(root)),
            TestSupport.entry(at: at(2026, 6, 21), input: 200, output: 0,
                              project: root, projectDir: ProjectKey.encode(root + "/sub")),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 2),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycleByProject.count == 1)
        #expect(agg.cycleByProject.first?.workTokens == 300)
    }

    /// The encoding rule itself, verified against all 15 real project directories on disk.
    @Test func encodingReplacesEveryNonAlphanumericWithADash() {
        #expect(ProjectKey.encode("/Users/napat/Desktop/LiDAR + HPE") == "-Users-napat-Desktop-LiDAR---HPE")
        #expect(ProjectKey.encode("/Users/napat/n8n Project/Testing") == "-Users-napat-n8n-Project-Testing")
        #expect(ProjectKey.encode("/Users/napat/Desktop/AAI/aai_next_dashboard") == "-Users-napat-Desktop-AAI-aai-next-dashboard")
        #expect(ProjectKey.encode("/Users/napat/Thai-Japan") == "-Users-napat-Thai-Japan")
    }

    /// A file's project is the component under `projects/`, never its own parent directory — a
    /// session's subagent transcripts live two levels deeper and must not become their own projects.
    @Test func theProjectDirectoryIsTheComponentUnderTheRootNotTheFilesParent() {
        let root = URL(fileURLWithPath: "/home/.claude/projects")
        let session = URL(fileURLWithPath: "/home/.claude/projects/-a-b/sess.jsonl")
        let subagent = URL(fileURLWithPath: "/home/.claude/projects/-a-b/sess/subagents/agent-1.jsonl")
        #expect(UsageScanner.projectDir(of: session, under: root) == "-a-b")
        #expect(UsageScanner.projectDir(of: subagent, under: root) == "-a-b")
        // Outside the root entirely → no project rather than a wrong one.
        #expect(UsageScanner.projectDir(of: URL(fileURLWithPath: "/tmp/x.jsonl"), under: root) == "")
        #expect(UsageScanner.projectDir(of: root, under: root) == "")
    }

    @Test func subagentTurnsAreAttributedToTheirParentProject() {
        // Subagent transcripts live under <project>/<session>/subagents/, and their lines carry the
        // same cwd — so the per-project split accounts for them without any extra plumbing.
        let entries = [
            TestSupport.entry(at: at(2026, 6, 20), input: 100, output: 0, project: "/a/one"),
            TestSupport.entry(at: at(2026, 6, 20), input: 400, output: 0, sidechain: true, project: "/a/one"),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: at(2026, 7, 2),
                                     calendar: cal, cycleWindow: cycle)
        #expect(agg.cycleByProject.count == 1)
        #expect(agg.cycleByProject.first?.workTokens == 500)
    }
}
