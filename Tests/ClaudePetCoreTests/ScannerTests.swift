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
