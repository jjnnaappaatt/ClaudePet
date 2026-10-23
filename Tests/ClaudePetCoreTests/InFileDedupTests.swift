import Testing
import Foundation
@testable import ClaudePetCore

/// The dedup-mode per-file cache keeps only the earliest copy of each message within a file
/// (`UsageScanner.appendKeepingEarliest`). Every merged figure is identical either way — that is the
/// point — so these pin the cache's *size* and the edge cases that could make the merge diverge.
@Suite struct InFileDedupTests {

    private func makeRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudepet-infile-\(UUID().uuidString)/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        return dir
    }

    private func line(_ id: String, at seconds: Int, input: Int = 10) -> String {
        let ts = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(seconds)))
            .replacingOccurrences(of: "Z", with: ".000Z")
        return """
        {"type":"assistant","timestamp":"\(ts)","cwd":"/tmp/p","isSidechain":false,\
        "message":{"id":"\(id)","model":"claude-opus-4-8",\
        "usage":{"input_tokens":\(input),"output_tokens":5}}}
        """
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    private func entry(_ id: String, _ t: Double) -> UsageEntry {
        TestSupport.entry(id: id, at: Date(timeIntervalSince1970: t))
    }

    @Test func keepsTheEarliestCopyAndLeavesProvisionalEntriesAtTheEnd() {
        var cached = [entry("a", 10), entry("b", 20)]
        let r = UsageScanner.appendKeepingEarliest(
            [entry("a", 15), entry("c", 30), entry("c", 25), entry("b", 21), entry("a", 99)],
            provisional: 1, to: &cached)
        #expect(cached.map(\.timestamp.timeIntervalSince1970) == [10, 20, 25, 99])
        #expect(r.added.map(\.timestamp.timeIntervalSince1970) == [25, 99])
        #expect(!r.replacedDelivered)
    }

    @Test func anEarlierCopyOfACachedEntryIsReportedAsReplacingADeliveredOne() {
        var cached = [entry("a", 10)]
        let r = UsageScanner.appendKeepingEarliest([entry("a", 5)], provisional: 0, to: &cached)
        #expect(cached.map(\.timestamp.timeIntervalSince1970) == [5])
        #expect(r.replacedDelivered)
    }

    /// The memory property itself. Mutation-checked: storing `parsed.entries` unfiltered fails here
    /// and nowhere else.
    @Test func theDedupCacheHoldsNoInFileRepeatsButTheCountingCacheDoes() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("p/s.jsonl")
        try append((0..<3).map { line("m", at: $0) }.joined(separator: "\n") + "\n" + line("n", at: 5) + "\n", to: f)

        let dedup = UsageScanner(root: root)
        #expect(await dedup.scan(deduplicated: true).count == 2)
        #expect(await dedup.cachedEntryCount == 2)

        let counting = UsageScanner(root: root)
        #expect(await counting.scan(deduplicated: false).count == 4)
        #expect(await counting.cachedEntryCount == 4)
    }

    @Test func anEarlierRepeatAppendedToTheSameFileMatchesAColdScan() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("p/s.jsonl")
        try append(line("m", at: 100, input: 1) + "\n" + line("n", at: 200) + "\n", to: f)
        let scanner = UsageScanner(root: root)
        _ = await scanner.scanChanges(deduplicated: true, changes: .everything)

        try append(line("m", at: 50, input: 2) + "\n", to: f)
        let d = await scanner.scanChanges(deduplicated: true, changes: .everything)
        guard case .full(let all) = d else { Issue.record("expected a full re-merge, got \(d)"); return }
        let cold = await UsageScanner(root: root).scan(deduplicated: true)
        #expect(all.map(\.inputTokens) == cold.map(\.inputTokens))
        #expect(all.first?.inputTokens == 2, "the earlier copy wins")
    }

    @Test func flippingTheModeRereadsAndMatchesAColdScan() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("p/s.jsonl")
        try append([line("m", at: 1), line("m", at: 2), line("n", at: 3)].joined(separator: "\n") + "\n", to: f)
        let scanner = UsageScanner(root: root)
        _ = await scanner.scanChanges(deduplicated: true, changes: .everything)

        // A `.paths` event that names nothing: the mode flip alone must force the full re-read.
        let d = await scanner.scanChanges(deduplicated: false, changes: .paths([]))
        guard case .full(let all) = d else { Issue.record("expected .full after a mode flip"); return }
        #expect(all.count == 3)
        #expect(await scanner.lastScanFullParses == 1)

        let back = await scanner.scanChanges(deduplicated: true, changes: .paths([]))
        guard case .full(let again) = back else { Issue.record("expected .full flipping back"); return }
        #expect(again.count == 2)
    }

    /// Copies of one message logged at the same instant used to be kept in whatever order the
    /// unstable sort left them, so the surviving token count changed between launches. Checked
    /// against the timestamp-only sort: these fail there, because the input order decided.
    @Test func equalTimestampCopiesResolveTheSameWayWhateverTheirOrder() {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let partial = TestSupport.entry(id: "m", at: t, input: 10, output: 3, projectDir: "-a")
        let complete = TestSupport.entry(id: "m", at: t, input: 10, output: 400, projectDir: "-b")
        let other = TestSupport.entry(id: "n", at: t.addingTimeInterval(-1), output: 1)
        for order in [[partial, complete, other], [complete, partial, other], [other, partial, complete]] {
            let merged = UsageScanner.merge(order, deduplicated: true)
            #expect(merged.map(\.outputTokens) == [1, 400], "order \(order.map(\.outputTokens))")
        }
        var a = [partial]; UsageScanner.appendKeepingEarliest([complete], provisional: 0, to: &a)
        var b = [complete]; UsageScanner.appendKeepingEarliest([partial], provisional: 0, to: &b)
        #expect(a.map(\.outputTokens) == [400])
        #expect(b.map(\.outputTokens) == [400])
    }
}
