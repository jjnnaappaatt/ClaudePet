import Testing
import Foundation
@testable import ClaudePetCore

/// The one path nothing covered: `MetricsStore.refresh()` reading real files off disk.
///
/// **`ScannerTests` proves `UsageScanner` dedups; this proves the store asks it to.** Every other
/// `MetricsStore` test feeds entries in through `ingestForTesting`, which assigns `lastEntries`
/// directly and never constructs a scanner — so `refresh()`'s single `deduplicated:` argument was
/// unprotected. Inverting it to `deduplicated: countRepeatedLogLines` roughly triples every token
/// figure in the app, and the entire suite stayed green. That is exactly the kind of defect the
/// numbers on screen cannot tell you about: they stay internally consistent, just all wrong
/// together, because the Auto budget anchors inflate alongside the usage they are fitted to.
@MainActor
@Suite struct ScannerWiringTests {

    private func line(id: String, ts: String, input: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
    }

    /// A root holding one file with a repeated `message.id` — the shape the real corpus has, where
    /// ~57% of logged lines re-log an id already seen, byte-identical.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudepet-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("proj"),
                                                withIntermediateDirectories: true)
        let f = root.appendingPathComponent("proj/session.jsonl")
        let body = [
            line(id: "msg_1", ts: "2026-06-05T10:00:00.000Z", input: 100),
            line(id: "msg_1", ts: "2026-06-05T10:00:00.000Z", input: 100),   // re-log, not new usage
            line(id: "msg_2", ts: "2026-06-05T10:05:00.000Z", input: 25),
        ].joined(separator: "\n")
        try body.write(to: f, atomically: true, encoding: .utf8)
        return root
    }

    private func store(root: URL) -> MetricsStore {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let s = MetricsStore(defaults: d, scannerRoot: root)
        s.statuslineCachePath = TestSupport.noStatuslineCache
        s.statsCachePath = TestSupport.noStatsCache
        s.tokenBasis = .work
        return s
    }

    @Test func refreshDeduplicatesByDefault() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let s = store(root: root)
        #expect(s.countRepeatedLogLines == false, "the default this test's expectation depends on")
        await s.refresh()

        // 100 + 25, with the repeated msg_1 counted once.
        #expect(s.allTime.workTokens == 125)
    }

    /// The opt-in "match /stats" mode, from disk. Not a preference round-trip — `PreferencesTests`
    /// already covers that and asserts nothing about the totals it changes.
    @Test func refreshCountsRepeatsWhenTheFlagIsSet() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let s = store(root: root)
        s.countRepeatedLogLines = true
        await s.refresh()

        // 100 + 100 + 25 — the re-logged line counted again, which is the whole point of the mode.
        #expect(s.allTime.workTokens == 225)
    }

    /// The two modes must actually differ. Written as its own assertion because the pair above
    /// would both still pass if `refresh()` ignored the flag and some other change moved both
    /// expectations — this one fails the moment the argument stops being wired through.
    @Test func theFlagChangesTheResultAtAll() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let deduped = store(root: root)
        await deduped.refresh()
        let raw = store(root: root)
        raw.countRepeatedLogLines = true
        await raw.refresh()

        #expect(raw.allTime.workTokens > deduped.allTime.workTokens,
                "refresh() is not passing countRepeatedLogLines to the scanner")
        #expect(raw.allTime.workTokens - deduped.allTime.workTokens == 100,
                "the difference must be exactly the re-logged line")
    }

    /// The `"usage"` prefilter skips 56.5% of lines before `JSONDecoder` — it must skip exactly the
    /// lines the decoder would have rejected anyway, and nothing else.
    ///
    /// The awkward cases are deliberate: a user line whose *text* contains the word usage without the
    /// key, and an assistant line whose `cwd` contains the quoted key as ordinary text. The first must
    /// still be skipped, the second must still be counted — a false negative here silently loses real
    /// tokens, which is the failure mode this whole file exists to prevent.
    @Test func theUsagePrefilterSkipsOnlyNonUsageLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudepet-prefilter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("mixed.jsonl")

        let body = [
            // Skipped: no usage key at all.
            #"{"type":"user","timestamp":"2026-06-05T10:00:00.000Z","message":{"content":"what is my usage today"}}"#,
            // Skipped: not an assistant turn, even though the key is present.
            #"{"type":"summary","timestamp":"2026-06-05T10:01:00.000Z","usage":{"input_tokens":9}}"#,
            // Counted.
            line(id: "msg_1", ts: "2026-06-05T10:02:00.000Z", input: 40),
            // Counted, and the tricky one: the literal key appears inside a string value too.
            #"{"type":"assistant","timestamp":"2026-06-05T10:03:00.000Z","cwd":"/tmp/\"usage\"-notes","message":{"id":"msg_2","model":"claude-opus-4-8","usage":{"input_tokens":2,"output_tokens":0}}}"#,
            // Skipped: junk.
            "not json at all",
        ].joined(separator: "\n")
        try body.write(to: f, atomically: true, encoding: .utf8)

        let got = try JSONLParser.entries(inFileAt: f, projectDir: "p")
        #expect(got.map(\.messageID) == ["msg_1", "msg_2"].map(MessageKey.init(hashing:)))
        #expect(got.reduce(0) { $0 + $1.workTokens } == 42)
    }

    /// Interning `model` and `cwd` must not change what is counted — it is an allocation
    /// optimisation, not a semantic one. Same file, parsed with and without a table.
    @Test func interningDoesNotChangeAnyFigure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("proj/session.jsonl")

        let plain = try JSONLParser.entries(inFileAt: f, projectDir: "proj")
        let interned = try JSONLParser.entries(inFileAt: f, projectDir: "proj",
                                               interner: StringInterner())
        #expect(plain == interned)
        #expect(interned.map(\.model) == plain.map(\.model))
        #expect(interned.map(\.project) == plain.map(\.project))
    }
}
