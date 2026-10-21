import Testing
import Foundation
@testable import ClaudePetCore

/// `StatsReplica` must land on Claude Code's own `/stats` numbers, and each rule below was needed to
/// do it on real data (see the type's doc comment). These pin the rules one at a time on fixtures,
/// so a "simplification" that drops one fails here rather than as a quiet few-percent drift.
@Suite struct StatsReplicaTests {

    private static let day = 20_381                          // 2025-10-20 as a `StatsDay` index
    private static func ts(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> String {
        let c = StatsDay.components(day + dayOffset)
        return String(format: "%04d-%02d-%02dT%02d:%02d:00.000Z", c.year!, c.month!, c.day!, hour, minute)
    }
    private static let now = Date(timeIntervalSince1970: Double(day + 1) * 86_400 + 12 * 3600)

    private static func user(_ t: String, sidechain: Bool = false) -> String {
        #"{"type":"user","isSidechain":\#(sidechain),"timestamp":"\#(t)","message":{"role":"user","content":"hi"}}"#
    }
    private static func assistant(_ t: String, model: String = "claude-opus-5-5", input: Int = 10,
                                  output: Int = 100, sidechain: Bool = false, id: String = "m") -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"timestamp":"\#(t)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":5000}}}"#
    }

    private final class Tree {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("statsreplica-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("-proj"),
                                                    withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func write(_ rel: String, _ lines: [String], mtime: Date? = nil) throws -> URL {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
            return url
        }
        func append(_ rel: String, _ lines: [String]) throws {
            let h = try FileHandle(forWritingTo: root.appendingPathComponent(rel))
            h.seekToEndOfFile()
            h.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            try h.close()
        }
    }

    private func delta(_ tree: Tree, from: Int? = StatsReplicaTests.day, limit: UInt64 = StatsReplica.tailLimit,
                       replica: StatsReplica? = nil) -> StatsDelta {
        (replica ?? StatsReplica(root: tree.root.path, tailLimit: limit))
            .delta(fromDay: from, now: Self.now, timeZone: TimeZone(secondsFromGMT: 7 * 3600)!)
    }

    @Test func dayIndexRoundTripsAndMatchesTheEpoch() {
        #expect(StatsDay.index(year: 1970, month: 1, day: 1) == 0)
        #expect(StatsDay.index(year: 2025, month: 10, day: 20) == Self.day)
        for i in [-1, 0, 59, 11_016, Self.day, 30_000] {
            #expect(StatsDay.index(of: StatsDay.components(i)) == i)
        }
    }

    @Test func countsMessagesSessionsAndTokensWithoutDedup() throws {
        let tree = try Tree()
        // The same API response logged twice: /stats counts both. ClaudePet's own figures would not.
        try tree.write("-proj/a.jsonl", [Self.user(Self.ts(0, 9)), Self.assistant(Self.ts(0, 9, 1)),
                                        Self.assistant(Self.ts(0, 9, 1))])
        let d = delta(tree)
        #expect(d.sessionCount == 1)
        #expect(d.totalMessages == 3)
        #expect(d.models["claude-opus-5-5"]?.workTokens == 220)
        #expect(d.models["claude-opus-5-5"]?.cacheReadTokens == 10_000)
    }

    @Test func daysAreUTCAndSessionHoursAreLocal() throws {
        let tree = try Tree()
        // 23:30Z is 06:30 the NEXT morning in UTC+7, but /stats files it under the UTC date.
        try tree.write("-proj/a.jsonl", [Self.user(Self.ts(0, 23, 30))])
        let d = delta(tree)
        #expect(d.dailyMessages == [Self.day: 1])
        #expect(d.hourCounts == [6: 1])
    }

    @Test func sidechainLinesInAMainTranscriptAreDroppedEntirely() throws {
        let tree = try Tree()
        try tree.write("-proj/a.jsonl", [Self.user(Self.ts(0, 9)),
                                        Self.assistant(Self.ts(0, 9, 5), sidechain: true)])
        let d = delta(tree)
        #expect(d.totalMessages == 1)
        #expect(d.models.isEmpty, "a sidechain turn's tokens must not count either")
    }

    @Test func subagentFilesCountTokensOnlyAndWorkflowAgentsAreNotListed() throws {
        let tree = try Tree()
        try tree.write("-proj/s1.jsonl", [Self.user(Self.ts(0, 9))])
        try tree.write("-proj/s1/subagents/agent-x.jsonl",
                       [Self.assistant(Self.ts(0, 9, 2), sidechain: true)])
        try tree.write("-proj/s1/subagents/workflows/wf_1/agent-y.jsonl", [Self.assistant(Self.ts(0, 9, 3))])
        try tree.write("-proj/s1/subagents/notes.jsonl", [Self.assistant(Self.ts(0, 9, 4))])
        let d = delta(tree)
        #expect(d.sessionCount == 1)
        #expect(d.totalMessages == 1)
        #expect(d.models["claude-opus-5-5"]?.workTokens == 110)
    }

    @Test func symlinkedTranscriptsAreNotFollowed() throws {
        let tree = try Tree()
        // Outside the root — anything inside it would be listed as a project of its own.
        let outside = try Tree()
        let real = try outside.write("-proj/a.jsonl", [Self.user(Self.ts(0, 9))])
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("-proj/link.jsonl"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("-linked"),
            withDestinationURL: outside.root.appendingPathComponent("-proj"))
        #expect(delta(tree).totalMessages == 0)
    }

    @Test func ignoresOtherLineTypesAndSyntheticTurns() throws {
        let tree = try Tree()
        try tree.write("-proj/a.jsonl", [
            #"{"type":"summary","summary":"x","timestamp":"\#(Self.ts(0, 8))"}"#,
            Self.user(Self.ts(0, 9)),
            Self.assistant(Self.ts(0, 9, 1), model: "<synthetic>"),
            "not json",
        ])
        let d = delta(tree)
        #expect(d.totalMessages == 2, "user + the synthetic assistant line both count as messages")
        #expect(d.models.isEmpty)
    }

    @Test func onlyDaysFromTheWatermarkCountAndASessionNeedsToStartThere() throws {
        let tree = try Tree()
        // Began the day before the range: its messages that day are the cache's, and it is the cache's
        // session — only today's messages are added.
        try tree.write("-proj/old.jsonl", [Self.user(Self.ts(-1, 9)), Self.user(Self.ts(0, 9))])
        try tree.write("-proj/new.jsonl", [Self.user(Self.ts(0, 10))])
        let d = delta(tree)
        #expect(d.sessionCount == 1)
        #expect(d.dailyMessages == [Self.day: 2])
    }

    @Test func filesNotTouchedSinceTheWatermarkAreNotRead() throws {
        let tree = try Tree()
        try tree.write("-proj/a.jsonl", [Self.user(Self.ts(0, 9))],
                       mtime: Date(timeIntervalSince1970: Double(Self.day - 1) * 86_400 + 3600))
        #expect(delta(tree).totalMessages == 0)
    }

    @Test func aBadFirstOrLastTimestampSkipsTheWholeFile() throws {
        let tree = try Tree()
        try tree.write("-proj/a.jsonl", [Self.user(Self.ts(0, 9)), Self.user("garbage")])
        #expect(delta(tree).sessionCount == 0)
        #expect(delta(tree).totalMessages == 0)
    }

    /// The rule that made the delta 12.7% high on real data when it was missing.
    @Test func aFileOverTheLimitIsReadFromItsTailOnly() throws {
        let tree = try Tree()
        let lines = (0..<10).map { Self.assistant(Self.ts(0, 9, $0), id: "m\($0)") }
        try tree.write("-proj/a.jsonl", lines)
        let lineBytes = UInt64(lines[0].utf8.count + 1)
        // A window of 3.5 lines: the first partial line is dropped, leaving 3.
        let d = delta(tree, limit: lineBytes * 7 / 2)
        #expect(d.totalMessages == 3)
        #expect(d.models["claude-opus-5-5"]?.workTokens == 330)
        // …and its session starts at the window's first line, not the file's.
        #expect(d.longestSession?.start == TimestampParser.date(from: Self.ts(0, 9, 7)))
    }

    @Test func anAppendIsResumedAndMatchesAColdRead() throws {
        let tree = try Tree()
        try tree.write("-proj/a.jsonl", [Self.user(Self.ts(0, 9)), Self.assistant(Self.ts(0, 9, 1))])
        let replica = StatsReplica(root: tree.root.path)
        _ = delta(tree, replica: replica)
        try tree.append("-proj/a.jsonl", [Self.user(Self.ts(0, 10)), Self.assistant(Self.ts(0, 11))])
        let warm = delta(tree, replica: replica)
        let cold = delta(tree)
        #expect(warm == cold)
        #expect(warm.totalMessages == 4)
        #expect(warm.longestSession?.duration == TimeInterval(2 * 3600))
    }

    // MARK: - Merge

    private func cache(lastDay: Int, daily: [Int: Int], sessions: Int = 10, messages: Int = 100,
                       work: (Int, Int) = (1_000, 9_000)) -> StatsCache {
        StatsCache(models: [StatsModelTotal(model: "claude-opus-5-5", inputTokens: work.0, outputTokens: work.1,
                                            cacheReadTokens: 0, cacheWriteTokens: 0)],
                   lastComputedDay: StatsDay.components(lastDay), totalSessions: sessions,
                   totalMessages: messages, dailyMessages: daily,
                   firstSessionDate: Date(timeIntervalSince1970: Double(lastDay - 9) * 86_400),
                   asOf: Self.now)
    }

    @Test func mergeAddsTheDeltaAndCountsTheStreakBackFromToday() {
        let today = StatsDay.index(of: Self.now)
        let c = cache(lastDay: today - 1, daily: [today - 3: 5, today - 2: 9, today - 1: 4])
        var d = StatsDelta(fromDay: today)
        d.sessionCount = 2
        d.dailyMessages = [today: 7]
        d.models = ["claude-opus-5-5": StatsModelTotal(model: "claude-opus-5-5", inputTokens: 5, outputTokens: 50,
                                                       cacheReadTokens: 0, cacheWriteTokens: 0)]
        let s = StatsSnapshot.merge(cache: c, delta: d, now: Self.now)
        #expect(s.isLive)
        #expect(s.totalWorkTokens == 10_055)
        #expect(s.totalSessions == 12)
        #expect(s.totalMessages == 107)
        #expect(s.activeDays == 4)
        #expect(s.currentStreak == 4)
        #expect(s.longestStreak == 4)
        #expect(s.mostActiveDay == StatsDay.components(today - 2))
    }

    /// Once Claude Code folds the delta's days in, adding it again would count them twice.
    @Test func aDeltaForAnOlderWatermarkIsIgnored() {
        let today = StatsDay.index(of: Self.now)
        var d = StatsDelta(fromDay: today - 1)
        d.dailyMessages = [today - 1: 50]
        let s = StatsSnapshot.merge(cache: cache(lastDay: today - 1, daily: [today - 1: 50]),
                                    delta: d, now: Self.now)
        #expect(!s.isLive)
        #expect(s.totalMessages == 100)
    }

    @Test func noActivityTodayMeansNoCurrentStreak() {
        let today = StatsDay.index(of: Self.now)
        let s = StatsSnapshot.merge(cache: cache(lastDay: today - 1, daily: [today - 2: 1, today - 1: 1]),
                                    delta: StatsDelta(fromDay: today), now: Self.now)
        #expect(s.currentStreak == 0, "/stats counts back from today, so an idle today ends it")
        #expect(s.longestStreak == 2)
    }
}

extension StatsReplicaTests {
    /// The favourite is ranked by tokens INCLUDING cache, as `/stats` ranks it — on real data that is
    /// Opus 5.5 while the input + output leader is Opus 4.8.
    @Test func favouriteModelRanksByTokensIncludingCache() {
        let writer = StatsModelTotal(model: "claude-opus-4-8", inputTokens: 1_000, outputTokens: 114_000,
                                     cacheReadTokens: 20_000_000, cacheWriteTokens: 0)
        let reader = StatsModelTotal(model: "claude-opus-5-5", inputTokens: 100, outputTokens: 41_000,
                                     cacheReadTokens: 30_000_000, cacheWriteTokens: 0)
        let c = StatsCache(models: [writer, reader], lastComputedDay: StatsDay.components(Self.day),
                           totalSessions: 1, asOf: Self.now)
        let s = StatsSnapshot.merge(cache: c, delta: nil, now: Self.now)
        #expect(s.models.first?.model == "claude-opus-4-8")
        #expect(s.favouriteModel?.model == "claude-opus-5-5")
        #expect(s.totalTokensIncludingCache == 50_156_100)
    }
}
