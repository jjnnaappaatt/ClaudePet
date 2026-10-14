import Testing
import Foundation
@testable import ClaudePetCore

/// Repeats of one `message.id` are **not** identical re-logs. Claude Code writes one line per content
/// block as a response streams, each carrying the usage known at that moment: on the real corpus the
/// copies of 72,984 of 73,016 repeated ids share input and cache counts while output only grows —
/// `3, 3, 3, 4313` — so the last copy is the response's real usage and the first is a snapshot of
/// its opening tokens. Keeping the first undercounted all-time output by 26% (42.1M against 57.2M).
///
/// It also made figures depend on file order. A forked subagent transcript carries the same line
/// (same uuid, same timestamp to the millisecond) into several files, and one of them can hold the
/// mid-stream snapshot: out=4 in one file, 8,530 in three others. "Earliest wins" ties there, the
/// sort can't break it, and the winner came from `Dictionary` iteration order — randomly seeded per
/// process — so every launch of the app read a different total. Measured: +82,777 work tokens
/// between a live scanner and a cold one over the same files.
@Suite struct RepeatedSnapshotTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func mergeKeepsTheFinalSnapshotAndTheFirstTimestamp() {
        let merged = UsageScanner.merge([
            TestSupport.entry(id: "m", at: t0, input: 131, output: 3, cacheRead: 900),
            TestSupport.entry(id: "m", at: t0.addingTimeInterval(2), input: 131, output: 3, cacheRead: 900),
            TestSupport.entry(id: "m", at: t0.addingTimeInterval(4), input: 131, output: 4313, cacheRead: 900),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.outputTokens == 4313)
        #expect(merged.first?.inputTokens == 131)
        #expect(merged.first?.timestamp == t0)       // stays where the turn began
    }

    /// The drift itself: identical timestamps, different usage, in either order.
    @Test func aTiedTimestampResolvesTheSameWayInEitherOrder() {
        let small = TestSupport.entry(id: "m", at: t0, input: 2, output: 4, projectDir: "a")
        let big = TestSupport.entry(id: "m", at: t0, input: 2, output: 8530, projectDir: "a")
        let one = UsageScanner.merge([small, big, big])
        let other = UsageScanner.merge([big, small, big])
        #expect(one == other)
        #expect(one.map(\.outputTokens) == [8530])
    }

    @Test func absorbingIsOrderIndependent() {
        let copies = [
            TestSupport.entry(id: "m", at: t0.addingTimeInterval(5), output: 9, projectDir: "late"),
            TestSupport.entry(id: "m", at: t0, output: 1, projectDir: "early"),
            TestSupport.entry(id: "m", at: t0.addingTimeInterval(1), output: 40, projectDir: "mid"),
        ]
        let results = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]].map { order in
            order.dropFirst().reduce(copies[order[0]]) { $0.absorbing(copies[$1]) }
        }
        #expect(Set(results.map(\.outputTokens)) == [40])
        #expect(Set(results.map(\.timestamp)) == [t0])
        #expect(Set(results.map(\.projectDir)) == ["early"])
    }

    /// The live path: a later, larger snapshot must reach the held array without a full re-merge —
    /// streaming writes several copies of every response, so falling back to `.full` would put the
    /// whole-history merge back on every write.
    @Test func aGrowingSnapshotUpgradesTheHeldEntryInPlace() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudepet-snap-\(UUID().uuidString)/projects", isDirectory: true)
        let f = root.appendingPathComponent("p/s.jsonl")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (Self.line("other", at: 0, output: 7) + "\n" + Self.line("m", at: 10, output: 3) + "\n")
            .write(to: f, atomically: false, encoding: .utf8)
        let scanner = UsageScanner(root: root)
        var held: [UsageEntry] = []
        guard case .full(let first) = await scanner.scanChanges(deduplicated: true, changes: .everything)
        else { Issue.record("first scan should be full"); return }
        held = first

        let h = try FileHandle(forWritingTo: f)
        try h.seekToEnd()
        try h.write(contentsOf: Data((Self.line("later", at: 11, output: 1) + "\n"
                                      + Self.line("m", at: 12, output: 4313) + "\n").utf8))
        try h.close()
        let d = await scanner.scanChanges(deduplicated: true, changes: .paths([f.path]))
        guard case .appended(let batch, let repeats) = d else { Issue.record("expected a delta, got \(d)"); return }
        UsageScanner.mergeAppended(batch, repeats: repeats, into: &held)

        let cold = await UsageScanner(root: root).scan()
        #expect(held == cold)
        #expect(held.first { $0.messageID == MessageKey(hashing: "m") }?.outputTokens == 4313)
        #expect(held.count == 3)
    }

    static func line(_ id: String, at seconds: Int, output: Int) -> String {
        let ts = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(seconds)))
            .replacingOccurrences(of: "Z", with: ".000Z")
        return """
        {"type":"assistant","timestamp":"\(ts)","cwd":"/tmp/p","isSidechain":false,\
        "message":{"id":"\(id)","model":"claude-opus-4-8",\
        "usage":{"input_tokens":2,"output_tokens":\(output)}}}
        """
    }
}
