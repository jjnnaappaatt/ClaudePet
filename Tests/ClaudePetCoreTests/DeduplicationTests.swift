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

    @Test func statefulDedupAcrossBatches() {
        var dedup = Deduplicator()
        let first = dedup.newEntries(from: [entry("a", work: 1), entry("b", work: 1)])
        let second = dedup.newEntries(from: [entry("b", work: 1), entry("c", work: 1)])
        #expect(first.map(\.messageID) == ["a", "b"])
        #expect(second.map(\.messageID) == ["c"])   // b already seen in batch 1
        #expect(dedup.uniqueCount == 3)
    }

    @Test func distinctIDsAllKept() {
        let raw = (0..<10).map { entry("id-\($0)", work: 1) }
        #expect(Deduplicator.deduplicated(raw).count == 10)
    }
}
