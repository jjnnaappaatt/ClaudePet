import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct ParserTests {

    static let assistantLine = #"""
    {"type":"assistant","timestamp":"2026-06-05T15:14:51.519Z","requestId":"req_1","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":200,"cache_creation_input_tokens":80,"cache_creation":{"ephemeral_5m_input_tokens":30,"ephemeral_1h_input_tokens":50}}}}
    """#

    @Test func parsesAssistantTokensAndCacheSplit() throws {
        let e = try #require(JSONLParser.entry(fromLine: Self.assistantLine))
        #expect(e.messageID == "msg_1")
        #expect(e.model == "claude-opus-4-8")
        #expect(e.family == .opus)
        #expect(e.inputTokens == 100)
        #expect(e.outputTokens == 50)
        #expect(e.cacheReadTokens == 200)
        #expect(e.cacheWrite5mTokens == 30)
        #expect(e.cacheWrite1hTokens == 50)
        #expect(e.workTokens == 150)
        #expect(e.totalTokens == 430)          // 100+50+200+30+50
        #expect(e.isSidechain == false)
    }

    @Test func parsesFractionalTimestamp() throws {
        let e = try #require(JSONLParser.entry(fromLine: Self.assistantLine))
        // 2026-06-05T15:14:51.519Z
        let expected = ISO8601DateFormatter().date(from: "2026-06-05T15:14:51Z")!
        #expect(abs(e.timestamp.timeIntervalSince(expected) - 0.519) < 0.01)
    }

    @Test func skipsSyntheticModel() {
        let line = #"{"type":"assistant","timestamp":"2026-06-05T15:14:51.519Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
        #expect(JSONLParser.entry(fromLine: line) == nil)
    }

    @Test func skipsNonAssistantLines() {
        let user = #"{"type":"user","timestamp":"2026-06-05T15:14:51.519Z","message":{"role":"user","content":"hi"}}"#
        let snap = #"{"type":"file-history-snapshot","timestamp":"2026-06-05T15:14:51.519Z"}"#
        let perm = #"{"type":"permission-mode","mode":"default"}"#
        #expect(JSONLParser.entry(fromLine: user) == nil)
        #expect(JSONLParser.entry(fromLine: snap) == nil)
        #expect(JSONLParser.entry(fromLine: perm) == nil)
    }

    @Test func fallsBackWhenNoCacheSplit() throws {
        let line = #"{"type":"assistant","timestamp":"2026-06-05T15:14:51.519Z","message":{"id":"m2","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":40}}}"#
        let e = try #require(JSONLParser.entry(fromLine: line))
        #expect(e.cacheWrite5mTokens == 40)    // whole creation bucket at 5m rate
        #expect(e.cacheWrite1hTokens == 0)
        #expect(e.family == .sonnet)
    }

    @Test func classifiesFamilies() {
        #expect(ModelFamily(modelID: "claude-opus-4-8") == .opus)
        #expect(ModelFamily(modelID: "claude-sonnet-4-6") == .sonnet)
        #expect(ModelFamily(modelID: "claude-haiku-4-5-20251001") == .haiku)
        #expect(ModelFamily(modelID: "some-future-model") == .other)
    }

    @Test func parsesMultipleLinesFromData() throws {
        let blob = Self.assistantLine + "\n" +
            #"{"type":"user","message":{"role":"user"}}"# + "\n" +
            #"{"type":"assistant","timestamp":"2026-06-05T16:00:00.000Z","message":{"id":"msg_9","model":"claude-haiku-4-5","usage":{"input_tokens":1,"output_tokens":1}}}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pt-\(UUID().uuidString).jsonl")
        try Data(blob.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = try JSONLParser.entries(inFileAt: url)
        #expect(entries.count == 2)            // user line skipped
        #expect(entries.map(\.messageID) == ["msg_1", "msg_9"])
    }
}
