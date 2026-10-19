import Testing
import Foundation
@testable import ClaudePetCore

/// `CodexRolloutReader` reads Codex's quota straight from `~/.codex/sessions`, porting the
/// statusline's `codex_usage` and `codex-week-tokens.py`. On the real corpus it was checked against
/// both to the token — six window starts, the whole 331 MB history included — so these pin the rules
/// that equivalence rests on, on fixtures small enough to reason about.
@Suite struct CodexRolloutTests {

    // MARK: - Fixtures

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// A fresh `root/2026/10/16/` with nothing in it.
    private func makeRoot() throws -> (root: String, day: String) {
        let root = NSTemporaryDirectory() + "cxr-\(UUID().uuidString)"
        let day = root + "/2026/10/16"
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        return (root, day)
    }

    private struct Window { let minutes: Int; let pct: Double; let resets: Date }

    /// One `token_count` record, shaped like Codex's own.
    private func line(at date: Date, input: Int, cached: Int = 0, output: Int,
                      limits: [Window]? = nil) -> String {
        var rl = "null"
        if let limits {
            let w = limits.map {
                #"{"used_percent":\#($0.pct),"window_minutes":\#($0.minutes),"resets_at":\#(Int($0.resets.timeIntervalSince1970))}"#
            }
            rl = #"{"limit_id":"codex","primary":\#(w[0]),"secondary":\#(w.count > 1 ? w[1] : "null")}"#
        }
        return #"{"timestamp":"\#(Self.iso.string(from: date))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}},"rate_limits":\#(rl)}}"#
    }

    private func write(_ lines: [String], to path: String, mtime: Date? = nil) throws {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path) }
    }

    private func append(_ text: String, to path: String) throws {
        let h = try #require(FileHandle(forWritingAtPath: path))
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Percentage

    @Test func readsBothWindowsShortFirstAndStampsTheRecordNotTheFile() throws {
        let (root, day) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        let recorded = now.addingTimeInterval(-3600.75)
        let week = Window(minutes: 10080, pct: 1, resets: now.addingTimeInterval(4 * 86_400))
        let session = Window(minutes: 300, pct: 4, resets: now.addingTimeInterval(3600))
        try write([line(at: recorded, input: 10, output: 5, limits: [week, session])],
                  to: day + "/rollout-a.jsonl")

        let limits = CodexRolloutReader(root: root).read()
        #expect(limits.map(\.windowMinutes) == [300, 10080])
        #expect(limits.map(\.utilization) == [4, 1])
        // The record's own whole second, fraction dropped — never the file's mtime.
        #expect(limits.first?.recordedAt.timeIntervalSince1970
                == recorded.timeIntervalSince1970.rounded(.down))
        #expect(limits.first?.resetsAt.timeIntervalSince1970
                == session.resets.timeIntervalSince1970.rounded(.down))
    }

    /// A rollout that has just started carries no snapshot yet; the reading lives in an older one.
    @Test func walksBackPastANewerRolloutWithNoSnapshot() throws {
        let (root, day) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        let week = Window(minutes: 10080, pct: 47, resets: now.addingTimeInterval(86_400))
        try write([line(at: now.addingTimeInterval(-600), input: 1, output: 1, limits: [week])],
                  to: day + "/rollout-old.jsonl", mtime: now.addingTimeInterval(-600))
        try write([line(at: now, input: 1, output: 1)], to: day + "/rollout-new.jsonl")

        #expect(CodexRolloutReader(root: root).read().map(\.utilization) == [47])
    }

    @Test func emptyWithoutCodex() {
        #expect(CodexRolloutReader(root: "/nonexistent/cxr-\(UUID().uuidString)").read().isEmpty)
    }

    /// Same rule as the cache reader: a window missing a field is dropped, never drawn as 0%.
    @Test func dropsAWindowWithAMissingField() throws {
        let (root, day) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let stamp = Self.iso.string(from: Date())
        try write([#"{"timestamp":"\#(stamp)","payload":{"rate_limits":{"primary":{"used_percent":5,"window_minutes":300}}}}"#],
                  to: day + "/rollout-a.jsonl")
        #expect(CodexRolloutReader(root: root).read().isEmpty)
    }

    // MARK: - Token count

    /// The script's rule, end to end: deltas of `input - cached + output`, the baseline taken from
    /// the record before the window, a repeated snapshot worth 0, and a dip clamped with the
    /// baseline following it down so the recovery is credited on the next record.
    @Test func tokenCountIsPositiveDeltasOfTheCacheExcludedCumulative() throws {
        let (root, day) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        let start = now.addingTimeInterval(-3600)
        let week = Window(minutes: 60, pct: 3, resets: now)   // window = the last hour
        try write([
            line(at: start.addingTimeInterval(-60), input: 1_000, output: 0),             // 1000, before: baseline only
            line(at: start.addingTimeInterval(10), input: 2_000, cached: 600, output: 100),  // 1500 → +500
            line(at: start.addingTimeInterval(20), input: 2_000, cached: 600, output: 100),  // 1500 → +0 (repeat)
            line(at: start.addingTimeInterval(30), input: 2_000, cached: 700, output: 100),  // 1400 → dip, 0
            line(at: start.addingTimeInterval(40), input: 2_100, cached: 700, output: 200),  // 1600 → +200
            line(at: start.addingTimeInterval(50), input: 2_100, cached: 700, output: 200, limits: [week]),
        ], to: day + "/rollout-a.jsonl")

        let reader = CodexRolloutReader(root: root)
        #expect(reader.tokensUsed(since: Int(start.timeIntervalSince1970)) == 700)
        #expect(reader.read().first?.tokensUsed == 700)
    }

    /// `nil`, never 0 — a Codex row claiming zero tokens in a week it was used is worse than none.
    @Test func noSpendIsUnknownRatherThanZero() throws {
        let (root, day) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        let week = Window(minutes: 10080, pct: 2, resets: now.addingTimeInterval(86_400))
        try write([line(at: now, input: 0, output: 0, limits: [week])], to: day + "/rollout-a.jsonl")
        #expect(CodexRolloutReader(root: root).read().first?.tokensUsed == nil)
    }

    /// The live rollout is read from where the last read stopped, and a half-written final line is
    /// left for the next read — it must neither be lost nor counted twice. Checked against a fresh
    /// reader at every step, which has no cache to be wrong with.
    @Test func resumesAnAppendAndWaitsForAHalfWrittenLine() throws {
        let (root, day) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        let start = Int(now.timeIntervalSince1970) - 3600
        let path = day + "/rollout-a.jsonl"
        try write([line(at: now.addingTimeInterval(-60), input: 100, output: 0)], to: path)

        let reader = CodexRolloutReader(root: root)
        #expect(reader.tokensUsed(since: start) == 100)

        let next = line(at: now.addingTimeInterval(-30), input: 350, output: 50)
        let cut = next.index(next.startIndex, offsetBy: next.count / 2)
        try append(String(next[..<cut]), to: path)
        #expect(reader.tokensUsed(since: start) == 100)
        #expect(CodexRolloutReader(root: root).tokensUsed(since: start) == 100)

        try append(String(next[cut...]) + "\n", to: path)
        #expect(reader.tokensUsed(since: start) == 400)
        #expect(CodexRolloutReader(root: root).tokensUsed(since: start) == 400)
    }

    /// A file that got shorter isn't the file that was cached; resuming into it mid-line would drop
    /// or invent records.
    @Test func aShorterFileIsReadFromTheStart() throws {
        let (root, day) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        let start = Int(now.timeIntervalSince1970) - 3600
        let path = day + "/rollout-a.jsonl"
        try write([line(at: now, input: 500, output: 0), line(at: now, input: 900, output: 0)], to: path)
        let reader = CodexRolloutReader(root: root)
        #expect(reader.tokensUsed(since: start) == 900)

        try write([line(at: now, input: 70, output: 0)], to: path)
        #expect(reader.tokensUsed(since: start) == 70)
    }

    // MARK: - MetricsStore wiring

    @MainActor private func store(root: String?, cache: String = TestSupport.noCodexCache) -> MetricsStore {
        let name = "cxr-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let s = TestSupport.store(defaults: d)
        s.codexUsageCachePath = cache
        s.codexSessionsRoot = root
        return s
    }

    /// A 5h row drew 4% for a window that had ended 68 hours earlier. Hiding it instead made the row
    /// vanish, which read as a missing feature — so an ended window stays, at 0%, marked reset, with
    /// no token count (that belonged to the window that ended) and its last-used time kept.
    @MainActor @Test func aWindowThatHasAlreadyResetIsShownEmpty() throws {
        let (root, day) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        let recorded = now.addingTimeInterval(-70 * 3600)
        let week = Window(minutes: 10080, pct: 1, resets: now.addingTimeInterval(4 * 86_400))
        let ended = Window(minutes: 300, pct: 4, resets: now.addingTimeInterval(-68 * 3600))
        try write([line(at: recorded, input: 100, output: 1, limits: [ended, week])],
                  to: day + "/rollout-a.jsonl", mtime: recorded)

        let s = store(root: root)
        s.recompute(now: now)
        #expect(s.codexUsage.map(\.windowMinutes) == [300, 10080])
        #expect(s.codexUsage.map(\.hasReset) == [true, false])
        #expect(s.codexUsage.map(\.utilization) == [0, 1])
        #expect(s.codexUsage.first?.tokensUsed == nil)
        #expect(s.codexUsage.first?.recordedAt.timeIntervalSince1970
                == recorded.timeIntervalSince1970.rounded(.down))
        // …and the weekly one flips the same way the moment it resets.
        s.recompute(now: now.addingTimeInterval(5 * 86_400))
        #expect(s.codexUsage.map(\.hasReset) == [true, true])
        #expect(s.codexUsage.map(\.utilization) == [0, 0])
    }

    @MainActor @Test func rolloutsWinOverTheCacheAndTheCacheIsTheFallback() throws {
        let (root, day) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        let cache = NSTemporaryDirectory() + "cxr-\(UUID().uuidString).tsv"
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let reset = Int(now.timeIntervalSince1970) + 86_400
        try "10080\t9.0\t\(reset)\t\(Int(now.timeIntervalSince1970))\n"
            .write(toFile: cache, atomically: true, encoding: .utf8)

        // No rollouts yet → the statusline's cache.
        let s = store(root: root, cache: cache)
        s.recompute(now: now)
        #expect(s.codexUsage.map(\.utilization) == [9])

        // A rollout with a snapshot → that, being the source the cache is computed from.
        let week = Window(minutes: 10080, pct: 12, resets: now.addingTimeInterval(86_400))
        try write([line(at: now, input: 1, output: 1, limits: [week])], to: day + "/rollout-a.jsonl")
        s.recompute(now: now)
        #expect(s.codexUsage.map(\.utilization) == [12])
    }
}
