import Testing
import Foundation
@testable import ClaudePetCore

private func writeTempTSV(_ text: String) -> String {
    let path = NSTemporaryDirectory() + "cxu-\(UUID().uuidString).tsv"
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func row(window: Int, pct: Double, resets: Date, recorded: Date) -> String {
    "\(window)\t\(pct)\t\(Int(resets.timeIntervalSince1970))\t\(Int(recorded.timeIntervalSince1970))"
}

/// Reads the terminal statusline's Codex cache — a local file, no token, no network. Real shape:
/// `window_minutes \t used_percent \t resets_at \t record_epoch`, the last two plain epochs.
@Suite struct CodexUsageTests {

    // MARK: - Parsing

    @Test func parsesTheSingleWindowCodexReportsToday() {
        let reset = Date().addingTimeInterval(7 * 86_400)
        let recorded = Date().addingTimeInterval(-600)
        let path = writeTempTSV(row(window: 10080, pct: 47.0, resets: reset, recorded: recorded) + "\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let limits = CodexUsageReader.read(path: path)
        #expect(limits.count == 1)
        #expect(limits.first?.windowMinutes == 10080)
        #expect(limits.first?.utilization == 47.0)
        #expect(abs((limits.first?.fraction ?? 0) - 0.47) < 1e-9)
        #expect(limits.first?.isUsable() == true)
    }

    /// Codex reported a 300-minute window alongside the weekly one until 2026-07-14 and the cache
    /// format still carries it, so two rows has to work before the day it comes back.
    @Test func twoWindowsComeBackShortestFirst() {
        let reset = Date().addingTimeInterval(3600)
        let recorded = Date()
        let path = writeTempTSV(
            row(window: 10080, pct: 60.0, resets: reset, recorded: recorded) + "\n" +
            row(window: 300, pct: 12.0, resets: reset, recorded: recorded) + "\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let limits = CodexUsageReader.read(path: path)
        #expect(limits.map(\.windowMinutes) == [300, 10080])   // matches the Claude rows' order
    }

    // MARK: - The optional token count

    @Test func readsTheTokenCountWhenTheCacheCarriesIt() {
        let reset = Date().addingTimeInterval(7 * 86_400)
        let path = writeTempTSV(row(window: 10080, pct: 16.0, resets: reset, recorded: Date()) + "\t21682073\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(CodexUsageReader.read(path: path).first?.tokensUsed == 21_682_073)
    }

    /// The shell script and the app ship separately, so a four-field cache written by an older
    /// statusline has to keep working rather than blanking the row.
    @Test func aFourFieldCacheStillParsesWithNoCount() {
        let reset = Date().addingTimeInterval(7 * 86_400)
        let path = writeTempTSV(row(window: 10080, pct: 16.0, resets: reset, recorded: Date()) + "\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let limits = CodexUsageReader.read(path: path)
        #expect(limits.count == 1)
        #expect(limits.first?.tokensUsed == nil)
        #expect(limits.first?.utilization == 16.0)
    }

    /// The cache writes 0 for "could not work it out". Rendering that as a real zero would claim
    /// Codex spent nothing in a week it was plainly used.
    @Test func zeroTokensReadsAsUnknownNotAsZero() {
        let reset = Date().addingTimeInterval(7 * 86_400)
        let path = writeTempTSV(row(window: 10080, pct: 16.0, resets: reset, recorded: Date()) + "\t0\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(CodexUsageReader.read(path: path).first?.tokensUsed == nil)
    }

    @Test func aSixthFieldIsRejectedRatherThanIgnored() {
        let reset = Date().addingTimeInterval(7 * 86_400)
        let path = writeTempTSV(row(window: 10080, pct: 16.0, resets: reset, recorded: Date()) + "\t123\textra\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(CodexUsageReader.read(path: path).isEmpty)
    }

    @Test func nonNumericTokenCountLeavesTheRowUsableWithoutIt() {
        let reset = Date().addingTimeInterval(7 * 86_400)
        let path = writeTempTSV(row(window: 10080, pct: 16.0, resets: reset, recorded: Date()) + "\tnull\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let limits = CodexUsageReader.read(path: path)
        #expect(limits.count == 1)              // the percentage is still good
        #expect(limits.first?.tokensUsed == nil)
    }

    @Test func missingFileReturnsNothing() {
        #expect(CodexUsageReader.read(path: "/tmp/nope-\(UUID().uuidString).tsv").isEmpty)
    }

    @Test func malformedFileReturnsNothing() {
        let path = writeTempTSV("not a tsv at all\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(CodexUsageReader.read(path: path).isEmpty)
    }

    /// A partial row is dropped, never defaulted. A Codex bar reading 0% because a field failed to
    /// parse is worse than no bar: nothing on screen would say the number was invented.
    @Test func shortRowIsSkippedNotDefaulted() {
        let path = writeTempTSV("10080\t47.0\t1786934485\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(CodexUsageReader.read(path: path).isEmpty)
    }

    @Test func nonNumericPercentageIsSkipped() {
        let path = writeTempTSV("10080\tnull\t1786934485\t1786329723\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(CodexUsageReader.read(path: path).isEmpty)
    }

    /// One bad row must not take a good one with it.
    @Test func goodRowSurvivesABadNeighbour() {
        let reset = Date().addingTimeInterval(3600)
        let path = writeTempTSV("garbage\n" + row(window: 10080, pct: 5.0, resets: reset, recorded: Date()) + "\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(CodexUsageReader.read(path: path).count == 1)
    }

    @Test func pastResetIsParsedButNotUsable() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        let limit = CodexLimit(windowMinutes: 10080, utilization: 47,
                               resetsAt: now.addingTimeInterval(-3600), recordedAt: now)
        #expect(limit.isUsable(now: now) == false)
        #expect(limit.utilization == 47)      // still parsed — the UI decides what to do with it
    }

    // MARK: - Age bands
    //
    // `now` is injected throughout: a band test against `Date()` passes or fails by when the suite
    // runs, which has already caused a real flaky failure in this project.

    private func limit(ageSeconds: TimeInterval, now: Date) -> CodexLimit {
        CodexLimit(windowMinutes: 10080, utilization: 47,
                   resetsAt: now.addingTimeInterval(86_400),
                   recordedAt: now.addingTimeInterval(-ageSeconds))
    }

    @Test func freshnessBandsAtEveryBoundary() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        #expect(limit(ageSeconds: 0, now: now).freshness(now: now) == .live)
        #expect(limit(ageSeconds: 3599, now: now).freshness(now: now) == .live)
        #expect(limit(ageSeconds: 3600, now: now).freshness(now: now) == .stale)
        #expect(limit(ageSeconds: 86_340, now: now).freshness(now: now) == .stale)   // 23h59m
        #expect(limit(ageSeconds: 86_400, now: now).freshness(now: now) == .stale)   // exactly a day
        #expect(limit(ageSeconds: 86_460, now: now).freshness(now: now) == .ancient) // 24h01m
    }

    /// A record stamped ahead of the clock must not read as fresher than live, or come out negative.
    @Test func futureRecordClampsToZeroAge() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        let l = limit(ageSeconds: -600, now: now)
        #expect(l.age(now: now) == 0)
        #expect(l.freshness(now: now) == .live)
    }

    /// The real case: on 2026-08-10 the reading was 65.1 hours old. Truncating days prints "2d ago",
    /// which undersells the staleness the label exists to report.
    @Test func sixtyFiveHoursRoundsToThreeDaysNotTwo() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        let recorded = now.addingTimeInterval(-65.1 * 3600)
        #expect(Format.relativeAge(from: recorded, now: now) == "3d ago")
    }

    @Test func dayRoundingAtItsBoundaries() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        func age(_ seconds: TimeInterval) -> String {
            Format.relativeAge(from: now.addingTimeInterval(-seconds), now: now)
        }
        #expect(age(86_400) == "1d ago")        // exactly a day
        #expect(age(36 * 3600) == "2d ago")     // 1.5d rounds up
        #expect(age(35 * 3600) == "1d ago")     // 1.46d rounds down
        #expect(age(31 * 86_400) == "31d ago")
        #expect(age(3600) == "1h ago")          // hour bucket still truncates, deliberately
        #expect(age(59) == "just now")
    }
}
