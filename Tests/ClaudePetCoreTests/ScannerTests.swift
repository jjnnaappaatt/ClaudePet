import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct ScannerTests {

    private func line(id: String, ts: String, input: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudepet-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("subagents"),
                                                withIntermediateDirectories: true)
        return root
    }

    @Test func dedupsAcrossFilesAndPicksUpChanges() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a.jsonl")
        let b = root.appendingPathComponent("subagents/agent-b.jsonl")  // subagent file is included
        try (line(id: "msg_1", ts: "2026-06-05T10:00:00.000Z", input: 100) + "\n" +
             line(id: "msg_2", ts: "2026-06-05T10:05:00.000Z", input: 10)).write(to: a, atomically: true, encoding: .utf8)
        try (line(id: "msg_1", ts: "2026-06-05T10:00:00.000Z", input: 100) + "\n" +   // duplicate of msg_1
             line(id: "msg_3", ts: "2026-06-05T10:10:00.000Z", input: 5)).write(to: b, atomically: true, encoding: .utf8)

        let scanner = UsageScanner(root: root)
        let first = await scanner.scan()
        #expect(first.count == 3)                                    // msg_1 deduped across files
        #expect(Set(first.map(\.messageID)) == ["msg_1", "msg_2", "msg_3"])

        // Append a new entry to b -> only b is re-parsed, new entry appears.
        let appended = try String(contentsOf: b, encoding: .utf8) + "\n" +
            line(id: "msg_4", ts: "2026-06-05T10:15:00.000Z", input: 7)
        try appended.write(to: b, atomically: true, encoding: .utf8)

        let second = await scanner.scan()
        #expect(second.count == 4)
        #expect(Set(second.map(\.messageID)) == ["msg_1", "msg_2", "msg_3", "msg_4"])
    }

    /// A transient read failure must not be cached. The cache key is (mtime, size) and a finished
    /// subagent transcript is never written again, so caching `[]` on a failed read would zero that
    /// file for the life of the process — silently, since the error is swallowed.
    @Test func transientReadFailureDoesNotPoisonTheCache() async throws {
        guard getuid() != 0 else { return }        // root ignores 0o000, so the failure can't be staged
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let a = root.appendingPathComponent("a.jsonl")
        try (line(id: "m1", ts: "2026-06-05T10:00:00.000Z", input: 100) + "\n" +
             line(id: "m2", ts: "2026-06-05T10:05:00.000Z", input: 10)).write(to: a, atomically: true, encoding: .utf8)

        let scanner = UsageScanner(root: root)
        #expect(await scanner.scan().count == 2)

        // Bump the mtime *and* revoke read access. The bump is essential: without it the
        // (mtime, size) cache hit short-circuits before any read and this path never runs.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_780_000_000)],
                             ofItemAtPath: a.path)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path) }

        // The prior good parse survives; it is not replaced by an empty result.
        #expect(await scanner.scan().count == 2)

        // And once the file is readable again, a later scan still sees it.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_780_000_100)],
                             ofItemAtPath: a.path)
        #expect(await scanner.scan().count == 2)
    }

    /// `deduplicated: false` reproduces Claude Code's `/stats` counting: every logged line, including
    /// the re-logs of a turn already recorded elsewhere. It counts one API response more than once
    /// by design — it is not recovering usage the deduplicated scan missed.
    @Test func nonDeduplicatedScanKeepsRepeatedLines() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a.jsonl")
        let b = root.appendingPathComponent("subagents/agent-b.jsonl")
        try (line(id: "msg_1", ts: "2026-06-05T10:00:00.000Z", input: 100) + "\n" +
             line(id: "msg_2", ts: "2026-06-05T10:05:00.000Z", input: 10)).write(to: a, atomically: true, encoding: .utf8)
        try line(id: "msg_1", ts: "2026-06-05T10:00:00.000Z", input: 100)
            .write(to: b, atomically: true, encoding: .utf8)   // same turn, logged twice

        let scanner = UsageScanner(root: root)
        let deduped = await scanner.scan()
        #expect(deduped.count == 2)
        #expect(deduped.map(\.inputTokens).reduce(0, +) == 110)

        let raw = await scanner.scan(deduplicated: false)
        #expect(raw.count == 3)
        #expect(raw.filter { $0.messageID == "msg_1" }.count == 2)     // the repeat is kept
        #expect(raw.map(\.inputTokens).reduce(0, +) == 210)            // …and its tokens counted twice

        // The mode only changes the merge: the per-file parse cache is shared, so switching back
        // costs no re-read and returns the original result.
        #expect(await scanner.scan().count == 2)
    }

    @Test func scanOnceMatchesActorScan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.jsonl")
        try (line(id: "x", ts: "2026-06-05T10:00:00.000Z", input: 1) + "\n" +
             line(id: "y", ts: "2026-06-05T10:01:00.000Z", input: 2)).write(to: a, atomically: true, encoding: .utf8)

        let once = UsageScanner.scanOnce(root: root)
        let actorScan = await UsageScanner(root: root).scan()
        #expect(Set(once.map(\.messageID)) == Set(actorScan.map(\.messageID)))
        #expect(once.count == 2)
    }
}
