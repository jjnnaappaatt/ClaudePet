import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct DeduplicationTests {

    private func entry(_ id: String, work: Int) -> UsageEntry {
        UsageEntry(messageID: id, timestamp: Date(), model: "claude-opus-4-8", family: .opus,
                   inputTokens: work, outputTokens: 0, cacheReadTokens: 0,
                   cacheWrite5mTokens: 0, cacheWrite1hTokens: 0, isSidechain: false)
    }

    @Test func keepsOneCopyPerMessageID_doesNotSum() {
        // Same id repeated with identical usage (as in real transcripts) + a distinct id.
        let raw = [entry("msg_1", work: 100), entry("msg_1", work: 100),
                   entry("msg_1", work: 100), entry("msg_2", work: 50)]
        let unique = Deduplicator.deduplicated(raw)
        #expect(unique.count == 2)
        #expect(unique.map(\.messageID) == ["msg_1", "msg_2"])
        #expect(unique.reduce(0) { $0 + $1.workTokens } == 150)   // NOT 350
    }

    /// Dedup spans batches — i.e. it is global across files, not per file.
    ///
    /// This used to drive `Deduplicator.newEntries`, a stateful API with zero production call sites:
    /// the scanner caches raw entries per file and dedups the whole concatenation at merge time,
    /// precisely so the result can't depend on which file a duplicate landed in. Re-pointed at
    /// `merge` so the property is still pinned against the code that actually runs.
    @Test func dedupSpansBatchesRatherThanFiles() {
        let batchA = [entry("a", work: 1), entry("b", work: 1)]
        let batchB = [entry("b", work: 1), entry("c", work: 1)]
        let merged = UsageScanner.merge(batchA + batchB)
        #expect(merged.map(\.messageID) == ["a", "b", "c"])
        #expect(merged.reduce(0) { $0 + $1.workTokens } == 3)   // b counted once, not twice
    }

    /// The same input with dedup off keeps every copy — the "match /stats" mode.
    @Test func mergeKeepsRepeatsWhenAskedTo() {
        let raw = UsageScanner.merge([entry("a", work: 1), entry("a", work: 1)], deduplicated: false)
        #expect(raw.count == 2)
        #expect(raw.reduce(0) { $0 + $1.workTokens } == 2)
    }

    @Test func distinctIDsAllKept() {
        let raw = (0..<10).map { entry("id-\($0)", work: 1) }
        #expect(Deduplicator.deduplicated(raw).count == 10)
    }
}
