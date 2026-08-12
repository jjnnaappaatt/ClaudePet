import Testing
import Foundation
@testable import ClaudePetCore

/// Resuming a parse from a byte offset instead of re-reading the whole file.
///
/// **A resumed parse and a full re-parse produce identical entries**, which is the point and also the
/// danger: every other test in the suite passes either way, so losing the incremental path would be
/// invisible except as the widget going back to burning a core. That is why `UsageScanner` exposes
/// `lastScanFullParses`/`lastScanTailParses` and why these tests assert on them — same reasoning as
/// `AllocationTests`.
///
/// The measurement that motivated it: the scanner's cache is keyed `(mtime, size)`, so one appended
/// line invalidated the whole file. On the developer's real corpus that meant a **180 MB** re-parse
/// for one live session and **682 MB** for another, several times a minute, against ~220 KB of new
/// data over twelve minutes.
@Suite struct IncrementalScanTests {

    private func makeRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudepet-inc-\(UUID().uuidString)/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A line the parser accepts. `id` drives dedup, so it must differ per line.
    private func line(_ id: String, at ts: String, input: Int = 10, output: Int = 5) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","cwd":"/tmp/proj","isSidechain":false,\
        "message":{"id":"\(id)","model":"claude-opus-4-8",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    private func ids(_ entries: [UsageEntry]) -> [MessageKey] { entries.map(\.messageID) }

    // MARK: - The core property

    /// **The headline test.** After an append, a resumed scan must equal what a cold scanner sees —
    /// and must actually have resumed rather than quietly re-read the file.
    @Test func appendingResumesAndMatchesAFullReparse() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("s.jsonl")
        try write(line("m1", at: "2026-08-10T01:00:00.000Z") + "\n"
                + line("m2", at: "2026-08-10T02:00:00.000Z") + "\n", to: f)

        let scanner = UsageScanner(root: root)
        let first = await scanner.scan()
        #expect(first.count == 2)
        #expect(await scanner.lastScanFullParses == 1)
        #expect(await scanner.lastScanTailParses == 0)

        try append(line("m3", at: "2026-08-10T03:00:00.000Z", input: 70, output: 30) + "\n", to: f)
        let second = await scanner.scan()

        // It resumed…
        #expect(await scanner.lastScanTailParses == 1)
        #expect(await scanner.lastScanFullParses == 0)
        // …and got exactly what a scanner that had never seen the file gets.
        let cold = await UsageScanner(root: root).scan()
        #expect(ids(second) == ids(cold))
        #expect(second.map(\.workTokens) == cold.map(\.workTokens))
        #expect(second.count == 3)
        #expect(second.last?.workTokens == 100)
    }

    /// Many small appends in a row — the real usage pattern, and the one where an off-by-one in the
    /// resume offset would compound instead of cancelling.
    @Test func manySuccessiveAppendsStayExact() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("s.jsonl")
        try write(line("m0", at: "2026-08-10T00:00:00.000Z") + "\n", to: f)
        let scanner = UsageScanner(root: root)
        _ = await scanner.scan()

        for i in 1...12 {
            try append(line("m\(i)", at: String(format: "2026-08-10T%02d:00:00.000Z", i)) + "\n", to: f)
            _ = await scanner.scan()
            #expect(await scanner.lastScanTailParses == 1, "append \(i) did not resume")
        }
        let got = await scanner.scan()
        let cold = await UsageScanner(root: root).scan()
        #expect(ids(got) == ids(cold))
        #expect(got.count == 13)
    }

    /// A line split across two scans: the first sees it unterminated, the second sees its newline.
    /// Without `tailCount` the turn is counted twice — and dedup would hide it in the default mode
    /// while `countRepeatedLogLines` (a supported setting) would show a doubled figure.
    @Test func anUnterminatedLineIsNotCountedTwiceWhenItsNewlineArrives() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("s.jsonl")
        try write(line("m1", at: "2026-08-10T01:00:00.000Z") + "\n"
                + line("m2", at: "2026-08-10T02:00:00.000Z"), to: f)   // no trailing newline

        let scanner = UsageScanner(root: root)
        let first = await scanner.scan(deduplicated: false)
        #expect(first.count == 2)                       // the unterminated line is still reported

        try append("\n" + line("m3", at: "2026-08-10T03:00:00.000Z") + "\n", to: f)
        let second = await scanner.scan(deduplicated: false)
        #expect(second.count == 3, "m2 was counted twice")
        #expect(ids(second) == ids(await UsageScanner(root: root).scan(deduplicated: false)))
    }

    // MARK: - When resuming must be refused

    /// Truncation must not be read as an append. The old offset would point past the new end.
    @Test func truncationFallsBackToAFullReparse() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("s.jsonl")
        try write(line("m1", at: "2026-08-10T01:00:00.000Z") + "\n"
                + line("m2", at: "2026-08-10T02:00:00.000Z") + "\n", to: f)
        let scanner = UsageScanner(root: root)
        #expect(await scanner.scan().count == 2)

        try write(line("m9", at: "2026-08-10T09:00:00.000Z") + "\n", to: f)   // shorter
        let after = await scanner.scan()
        #expect(await scanner.lastScanFullParses == 1)
        #expect(await scanner.lastScanTailParses == 0)
        #expect(after.count == 1)
        #expect(ids(after) == ids(await UsageScanner(root: root).scan()))
    }

    /// A file rewritten to the *same or greater* length with different content earlier in it. Size
    /// alone cannot catch this; the boundary fingerprint is the only thing that does.
    @Test func aRewrittenPrefixFallsBackToAFullReparse() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("s.jsonl")
        try write(line("m1", at: "2026-08-10T01:00:00.000Z") + "\n"
                + line("m2", at: "2026-08-10T02:00:00.000Z") + "\n", to: f)
        let scanner = UsageScanner(root: root)
        _ = await scanner.scan()

        // Same shape, same length, different ids — a rewrite, not an append.
        try write(line("z1", at: "2026-08-10T01:00:00.000Z") + "\n"
                + line("z2", at: "2026-08-10T02:00:00.000Z") + "\n"
                + line("z3", at: "2026-08-10T03:00:00.000Z") + "\n", to: f)
        let after = await scanner.scan()
        #expect(await scanner.lastScanFullParses == 1, "a rewritten prefix must not resume")
        #expect(after.count == 3)
        #expect(ids(after) == ids(await UsageScanner(root: root).scan()))
    }

    /// A file with no newline at all has consumed nothing, so there is no offset to vouch for and it
    /// stays on the full path however many times it is scanned.
    @Test func aNewlineFreeFileStaysOnTheFullPath() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("s.jsonl")
        try write(line("m1", at: "2026-08-10T01:00:00.000Z"), to: f)      // no newline
        let scanner = UsageScanner(root: root)
        #expect(await scanner.scan().count == 1)

        try append(line("m2", at: "2026-08-10T02:00:00.000Z"), to: f)     // still no newline
        let after = await scanner.scan()
        #expect(await scanner.lastScanFullParses == 1)
        #expect(await scanner.lastScanTailParses == 0)
        // Two unterminated records run together into ONE malformed line, which decodes to nothing.
        // That is exactly what the pre-incremental code did with the same bytes, so it is the
        // behaviour being preserved rather than a new edge — and the moment a newline separates
        // them both lines parse.
        #expect(after.isEmpty)
        #expect(ids(after) == ids(await UsageScanner(root: root).scan()))
    }

    /// An untouched file is neither re-parsed nor resumed — the `(mtime, size)` short-circuit still
    /// comes first, and it is what keeps 2,499 unchanged files free.
    @Test func anUnchangedFileIsNotParsedAtAll() async throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("s.jsonl")
        try write(line("m1", at: "2026-08-10T01:00:00.000Z") + "\n", to: f)
        let scanner = UsageScanner(root: root)
        _ = await scanner.scan()
        _ = await scanner.scan()
        #expect(await scanner.lastScanFullParses == 0)
        #expect(await scanner.lastScanTailParses == 0)
    }

    // MARK: - The offset contract

    /// `parsedUpTo` must land after the last **complete** newline, never inside a partial line.
    @Test func parsedUpToStopsAtTheLastCompleteNewline() throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("s.jsonl")
        let a = line("m1", at: "2026-08-10T01:00:00.000Z") + "\n"
        let partial = line("m2", at: "2026-08-10T02:00:00.000Z")     // unterminated
        try write(a + partial, to: f)

        let parsed = try JSONLParser.parse(fileAt: f, from: 0)
        #expect(parsed.parsedUpTo == UInt64(a.utf8.count))
        #expect(parsed.tailCount == 1)
        #expect(parsed.entries.count == 2)

        // Resuming from there re-reads exactly the partial line and nothing else.
        let resumed = try JSONLParser.parse(fileAt: f, from: parsed.parsedUpTo)
        #expect(resumed.entries.count == 1)
        #expect(resumed.parsedUpTo == parsed.parsedUpTo)   // still no newline, so still nothing consumed
        #expect(resumed.tailCount == 1)
    }

    /// The boundary fingerprint has to actually depend on the bytes, or the guard is decoration.
    @Test func boundaryHashChangesWithTheBytesItCovers() throws {
        let root = try makeRoot()
        let f = root.appendingPathComponent("s.jsonl")
        try write("hello\nworld\n", to: f)
        let h1 = UsageScanner.boundaryHash(of: f, endingAt: 12)
        try write("hello\nworlD\n", to: f)
        let h2 = UsageScanner.boundaryHash(of: f, endingAt: 12)
        #expect(h1 != nil)
        #expect(h1 != h2)
        #expect(UsageScanner.boundaryHash(of: f, endingAt: 0) == nil)   // nothing consumed yet
        // Deterministic within a run: same bytes, same answer.
        #expect(UsageScanner.boundaryHash(of: f, endingAt: 12) == h2)
    }
}
