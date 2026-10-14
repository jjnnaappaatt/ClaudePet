import Testing
import Foundation
@testable import ClaudePetCore

/// `UsageScanner.scanChanges` answering with a delta instead of re-merging the whole history.
///
/// Same hazard as `IncrementalScanTests`: a delta applied correctly and a full re-merge give the
/// same entries, so the suite can't tell them apart — these tests assert both that the result
/// matches a cold scan **and** that the cheap path was actually taken.
@Suite struct DeltaScanTests {

    private func makeRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudepet-delta-\(UUID().uuidString)/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p/s/subagents"),
                                                withIntermediateDirectories: true)
        return dir
    }

    private func line(_ id: String, at seconds: Int, input: Int = 10, output: Int = 5) -> String {
        let ts = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(seconds)))
            .replacingOccurrences(of: "Z", with: ".000Z")
        return """
        {"type":"assistant","timestamp":"\(ts)","cwd":"/tmp/p","isSidechain":false,\
        "message":{"id":"\(id)","model":"claude-opus-4-8",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    /// FSEvents reports resolved paths (`/private/var/…`), not the `/var/…` spelling the root
    /// was built with — use that spelling here so the mapping is exercised too.
    private func eventPath(_ url: URL, root: URL) -> String {
        let rel = url.path.dropFirst(root.path.count)
        return root.resolvingSymlinksInPath().path + rel
    }

    private struct Row: Hashable { let id: MessageKey; let t: Date; let input: Int; let output: Int }
    private func rows(_ e: [UsageEntry]) -> [Row] {
        e.map { Row(id: $0.messageID, t: $0.timestamp, input: $0.inputTokens, output: $0.outputTokens) }
            .sorted { ($0.t, $0.input, $0.output, $0.id.hashValue) < ($1.t, $1.input, $1.output, $1.id.hashValue) }
    }

    private func apply(_ d: ScanDelta, to held: inout [UsageEntry]) {
        switch d {
        case .unchanged: break
        case .appended(let batch, let repeats): UsageScanner.mergeAppended(batch, repeats: repeats, into: &held)
        case .full(let all): held = all
        }
    }

    @Test func plainAppendIsADeltaAndMatchesAColdScan() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("p/s.jsonl")
        try append(line("a", at: 0) + "\n" + line("b", at: 10) + "\n", to: f)
        let scanner = UsageScanner(root: root)
        var held: [UsageEntry] = []
        apply(await scanner.scanChanges(deduplicated: true, changes: .everything), to: &held)
        #expect(held.count == 2)

        try append(line("c", at: 20) + "\n" + line("a", at: 21) + "\n", to: f)   // one new, one repeat
        let d = await scanner.scanChanges(deduplicated: true, changes: .paths([eventPath(f, root: root)]))
        guard case .appended(let batch, let repeats) = d else { Issue.record("expected .appended, got \(d)"); return }
        #expect(batch.count == 1)                       // the repeat of "a" is folded in, not appended
        #expect(repeats.count == 1)
        apply(d, to: &held)
        #expect(rows(held) == rows(await UsageScanner(root: root).scan()))
        #expect(held.map(\.timestamp) == held.map(\.timestamp).sorted())
    }

    @Test func aNewFileIsADeltaButADeletedOneIsFull() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("p/s.jsonl")
        try append(line("a", at: 0) + "\n", to: f)
        let scanner = UsageScanner(root: root)
        _ = await scanner.scanChanges(deduplicated: true, changes: .everything)

        let g = root.appendingPathComponent("p/s/subagents/agent-1.jsonl")
        try append(line("x", at: 5) + "\n", to: g)
        let added = await scanner.scanChanges(deduplicated: true, changes: .paths([eventPath(g, root: root)]))
        guard case .appended = added else { Issue.record("new file should be a delta"); return }

        try FileManager.default.removeItem(at: g)
        let removed = await scanner.scanChanges(deduplicated: true, changes: .paths([eventPath(g, root: root)]))
        guard case .full(let all) = removed else { Issue.record("deletion must re-merge"); return }
        #expect(all.count == 1)
    }

    /// A copy that is *earlier* than the one delivered moves the held entry back to its timestamp
    /// (and brings its own usage if larger) — still as a delta, not a full re-merge.
    @Test func anEarlierRepeatMovesTheHeldEntry() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("p/s.jsonl")
        let g = root.appendingPathComponent("p/t.jsonl")
        try append(line("dup", at: 100, input: 1) + "\n" + line("mid", at: 75) + "\n", to: f)
        let scanner = UsageScanner(root: root)
        var held: [UsageEntry] = []
        apply(await scanner.scanChanges(deduplicated: true, changes: .everything), to: &held)
        try append(line("dup", at: 50, input: 1, output: 900) + "\n", to: g)
        let d = await scanner.scanChanges(deduplicated: true, changes: .paths([eventPath(g, root: root)]))
        guard case .appended = d else { Issue.record("expected a delta, got \(d)"); return }
        apply(d, to: &held)
        #expect(rows(held) == rows(await UsageScanner(root: root).scan()))
        #expect(held.map(\.outputTokens) == [900, 5])  // moved before "mid", larger usage kept
    }

    @Test func mergeAppendedReSortsOnlyWhatInterleaves() {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        var held = (0..<5).map { TestSupport.entry(id: "h\($0)", at: t.addingTimeInterval(Double($0 * 10))) }
        let batch = [TestSupport.entry(id: "n1", at: t.addingTimeInterval(25)),
                     TestSupport.entry(id: "n2", at: t.addingTimeInterval(60))]
        UsageScanner.mergeAppended(batch, into: &held)
        #expect(held.map { Int($0.timestamp.timeIntervalSince(t)) } == [0, 10, 20, 25, 30, 40, 60])
    }

    /// The property that matters, under churn: whatever sequence of appends, repeats, interleaved
    /// writers, partial lines, rewrites and deletions happens, the array a caller builds from deltas
    /// equals what a cold scanner reads — in both counting modes, via both event shapes.
    @Test(arguments: [true, false])
    func randomizedChurnMatchesColdScans(deduplicated: Bool) async throws {
        let root = try makeRoot()
        let files = ["p/s.jsonl", "p/t.jsonl", "p/s/subagents/agent-1.jsonl", "p/s/subagents/agent-2.jsonl"]
            .map { root.appendingPathComponent($0) }
        var rng = SplitMix(seed: deduplicated ? 7 : 11)
        let scanner = UsageScanner(root: root)
        var held: [UsageEntry] = []
        var clock = 0
        var ids: [String] = []
        var partial: [URL: String] = [:]
        var deltas = 0
        var lastOp = -1

        for step in 0..<160 {
            let f = files[Int(rng.next() % UInt64(files.count))]
            let op = rng.next() % 10
            lastOp = Int(op)
            switch op {
            case 0...4:                                   // append fresh lines, mostly in order
                for _ in 0..<(1 + Int(rng.next() % 3)) {
                    clock += Int(rng.next() % 20)
                    let id = "m\(step)-\(rng.next() % 1000)"
                    ids.append(id)
                    try append(line(id, at: clock - Int(rng.next() % 15)) + "\n", to: f)
                }
            case 5:                                       // a later snapshot of an earlier message
                if let id = ids.randomElement(using: &rng) {
                    clock += 1
                    try append(line(id, at: clock, output: Int(rng.next() % 5000)) + "\n", to: f)
                }
            case 6:                                       // half-written line, finished next time
                if let rest = partial.removeValue(forKey: f) {
                    try append(rest + "\n", to: f)
                } else {
                    clock += 3
                    let l = line("p\(step)", at: clock)
                    // Either a line cut mid-JSON (no entry yet), or a whole line still missing
                    // its newline — which parses, is handed out, and must be withdrawn when the
                    // newline lands and the line is read again as part of the next tail.
                    let cut = step % 2 == 0 ? l.endIndex : l.index(l.startIndex, offsetBy: l.count / 2)
                    try append(String(l[..<cut]), to: f)
                    partial[f] = String(l[cut...])
                }
            case 7:                                       // rewrite from scratch
                partial[f] = nil
                try (line("r\(step)", at: clock) + "\n").write(to: f, atomically: true, encoding: .utf8)
            case 8:                                       // delete
                partial[f] = nil
                try? FileManager.default.removeItem(at: f)
            case 9 where step % 3 == 0:                   // a forked transcript: same instant, any usage
                if let id = ids.randomElement(using: &rng) {
                    try append(line(id, at: clock, output: Int(rng.next() % 5000)) + "\n", to: f)
                    try append(line(id, at: clock, output: Int(rng.next() % 5000)) + "\n",
                               to: files[Int(rng.next() % UInt64(files.count))])
                }
            default:
                break                                     // an event with nothing new
            }
            let changes: FileChanges = rng.next() % 4 == 0
                ? .everything : .paths([eventPath(f, root: root)])
            let d = await scanner.scanChanges(deduplicated: deduplicated, changes: op == 9 ? .everything : changes)
            if case .appended = d { deltas += 1 }
            apply(d, to: &held)
            let cold = await UsageScanner(root: root).scan(deduplicated: deduplicated)
            #expect(rows(held) == rows(cold), "step \(step) op \(lastOp) held \(held.count) cold \(cold.count) extra \(Set(rows(held)).subtracting(rows(cold)).map(\.input)) missing \(Set(rows(cold)).subtracting(rows(held)).map(\.input))")
            #expect(held.map(\.timestamp) == held.map(\.timestamp).sorted(), "step \(step) order")
        }
        #expect(deltas > 30)                              // and the cheap path really was used
    }
}

/// Deterministic, so a failure reproduces.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
