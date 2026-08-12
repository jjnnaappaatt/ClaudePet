import Foundation

/// Canonicalises the handful of strings that repeat across every logged line.
///
/// **`model` and `cwd` come back from `JSONDecoder` as a fresh `String` per line, and both exceed
/// Swift's 15-byte inline limit — so each one heap-allocates.** Measured on a real corpus that is
/// 125,100 entries: 250,200 allocations carrying about **130 distinct values** (7 model ids, ~120
/// working directories). Handing back a shared instance collapses that to 130, and because `String`
/// is copy-on-write every `UsageEntry` then points at the same storage instead of its own.
///
/// A plain dictionary, deliberately: this is created per scan and threaded through, so it is only
/// ever touched from inside the scanner actor (or from one synchronous `scanOnce` call). Making it
/// global would buy cross-scan reuse and cost a lock on the hottest loop in the app.
///
/// `messageID` is **not** interned — it is unique per entry by construction, so a table of them
/// would be pure overhead on top of the allocations it cannot remove.
public final class StringInterner {
    private var table: [String: String] = [:]

    public init() { table.reserveCapacity(256) }

    public func intern(_ s: String) -> String {
        if let hit = table[s] { return hit }
        table[s] = s
        return s
    }
}

/// Decodes line-delimited transcript files into normalized `UsageEntry` values.
/// Skips every line that isn't a real, priced assistant turn.
public enum JSONLParser {

    private static let decoder = JSONDecoder()

    /// Decode a single JSONL line. Returns nil for non-usage lines
    /// (user/file-history/permission-mode/synthetic, or undecodable).
    ///
    /// `projectDir` is the `~/.claude/projects/<dir>` folder the line came from. A single line can't
    /// know it, so the caller supplies it — it's the exact per-project grouping key, where the line's
    /// own `cwd` is only the per-turn directory. See `ProjectKey`.
    public static func entry(fromLineData data: Data, projectDir: String = "",
                             interner: StringInterner? = nil) -> UsageEntry? {
        guard let record = try? decoder.decode(LogRecord.self, from: data) else { return nil }
        guard record.type == "assistant",
              let message = record.message,
              let model = message.model,
              model != "<synthetic>",
              let usage = message.usage,
              let tsString = record.timestamp,
              let timestamp = TimestampParser.date(from: tsString)
        else { return nil }

        // Dedup key: prefer message.id, fall back to requestId.
        guard let messageID = message.id ?? record.requestId else { return nil }

        let totalCreate = usage.cache_creation_input_tokens ?? 0
        let cw5m: Int
        let cw1h: Int
        if let cc = usage.cache_creation {
            cw5m = cc.ephemeral_5m_input_tokens ?? 0
            cw1h = cc.ephemeral_1h_input_tokens ?? 0
        } else {
            // No TTL split available — bill the whole creation bucket at the 5m (1.25×) rate.
            cw5m = totalCreate
            cw1h = 0
        }

        // Interned, not copied: these two repeat across every line of every file (see
        // `StringInterner`). `projectDir` needs no interning — the caller passes one instance per
        // file, so every entry from that file already shares it.
        let cwd = record.cwd ?? ""
        return UsageEntry(
            messageID: MessageKey(hashing: messageID),
            timestamp: timestamp,
            model: interner?.intern(model) ?? model,
            family: ModelFamily(modelID: model),
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0,
            cacheWrite5mTokens: cw5m,
            cacheWrite1hTokens: cw1h,
            isSidechain: record.isSidechain ?? false,
            project: interner?.intern(cwd) ?? cwd,
            projectDir: projectDir
        )
    }

    /// Convenience for tests / fixtures.
    public static func entry(fromLine line: String, projectDir: String = "") -> UsageEntry? {
        entry(fromLineData: Data(line.utf8), projectDir: projectDir)
    }

    /// Parse one file into usage entries, streaming it in fixed chunks so peak memory is
    /// ~one chunk plus the longest line — never the whole file. (Transcripts reach 100 MB+;
    /// `Data(contentsOf:)` would spike RSS that much on every re-read.) Bad lines are
    /// skipped; a read error is thrown.
    /// Cheap reject before `JSONDecoder`: a line that never spells `"usage"` cannot carry a usage
    /// object, so it cannot become a `UsageEntry`.
    ///
    /// **Most logged lines are not assistant turns.** Measured on the real corpus: 289,259 lines, of
    /// which 125,806 contain the key — so **56.5% were being fully decoded into a `LogRecord`, with
    /// all its nested strings, purely to be dropped by the `record.type == "assistant"` check one line
    /// later.** A substring test skips them before a single allocation.
    ///
    /// One-directional by construction, which is what makes it safe: a false positive costs a decode
    /// that would have happened anyway, and a false negative is impossible, because the key cannot be
    /// present in the parsed JSON without the bytes being present in the line.
    /// `"usage"` — quotes included — as raw bytes, for the hand-rolled scan below.
    private static let usageKeyBytes: [UInt8] = Array(#""usage""#.utf8)

    /// What one pass over a file produced, and how far it got.
    public struct FileParse {
        public let entries: [UsageEntry]
        /// Byte offset **after the last complete newline**. A resumed parse starts exactly here, so
        /// an unterminated final line is deliberately *not* counted as consumed.
        public let parsedUpTo: UInt64
        /// How many of `entries` came from an unterminated final line. Those are provisional: the
        /// next parse re-reads that region once its newline arrives, so a caller appending to a
        /// cached array must drop this many from the tail first or it double-counts the turn.
        public let tailCount: Int
    }

    public static func entries(inFileAt url: URL, projectDir: String = "",
                               interner: StringInterner? = nil) throws -> [UsageEntry] {
        try parse(fileAt: url, from: 0, projectDir: projectDir, interner: interner).entries
    }

    /// Parse from `offset` to EOF.
    ///
    /// **This is the fix for the app's dominant CPU cost.** The scanner's cache is keyed on
    /// `(mtime, size)`, so before this existed a single appended line invalidated the whole file and
    /// it was re-parsed from byte zero. Transcripts are append-only and reach hundreds of MB —
    /// measured live, one appended line cost a **180 MB** re-parse on one session and **682 MB** on
    /// another, against roughly 220 KB of genuinely new data across twelve minutes. The widget sat at
    /// 45–100% of a core because a rescan takes longer than the interval between file writes.
    ///
    /// Resuming is a small extension rather than a rewrite because the chunk loop already had to
    /// carry a partial line across 1 MB boundaries; `offset` just starts it somewhere other than 0.
    public static func parse(fileAt url: URL, from offset: UInt64, projectDir: String = "",
                             interner: StringInterner? = nil) throws -> FileParse {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: offset) }

        var result: [UsageEntry] = []
        var buffer = Data()
        var consumed = offset
        var newlines: [Int] = []          // reused across chunks; one allocation, not one per chunk
        let chunkSize = 1 << 20           // 1 MB

        while case let chunk = handle.readData(ofLength: chunkSize), !chunk.isEmpty {
            // Drain per chunk: JSON decoding spins off many autoreleased Foundation
            // temporaries; without this they pile up to a huge peak over a 100 MB+ file.
            autoreleasepool {
                buffer.append(chunk)
                lineOffsets(in: buffer, into: &newlines)
                guard let lastNewline = newlines.last else { return }
                var lineStart = 0
                for nl in newlines {
                    // Slices, not `subdata`. `Data.SubSequence` IS `Data`, so both of these copies
                    // were pure overhead: one of the whole chunk, then one per line. On a 1.9 GB
                    // corpus that was roughly 4 GB of transient copying for no gain — `JSONDecoder`
                    // accepts a slice with a non-zero start index perfectly well.
                    if nl > lineStart {
                        let slice = buffer[(buffer.startIndex + lineStart)..<(buffer.startIndex + nl)]
                        if containsUsageKey(slice),
                           let entry = entry(fromLineData: slice, projectDir: projectDir,
                                             interner: interner) {
                            result.append(entry)
                        }
                    }
                    lineStart = nl + 1
                }
                consumed += UInt64(lastNewline + 1)
                // In place. The old `buffer = buffer.subdata(in:…)` allocated a fresh `Data` for
                // every megabyte of every file.
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + lastNewline + 1))
            }
        }
        // A final line with no trailing newline. Kept for files that genuinely lack one — but it does
        // NOT advance `consumed`, because far more often it is simply a half-written append that will
        // be complete a moment later. `tailCount` tells the caller these are provisional.
        var tailCount = 0
        if !buffer.isEmpty, containsUsageKey(buffer),
           let entry = entry(fromLineData: buffer, projectDir: projectDir, interner: interner) {
            result.append(entry)
            tailCount = 1
        }
        return FileParse(entries: result, parsedUpTo: consumed, tailCount: tailCount)
    }

    /// Byte offsets of every `\n` in `data`, written into `out` (cleared first, capacity reused).
    ///
    /// Replaces `Data.split(separator:)`, which was **1015 of 3103 samples inside the scan — 28%**,
    /// the single largest slice of it. `Collection.split` on `Data` goes through generic element
    /// access and materialises an array of `Data` sub-sequences; `memchr` walks the raw bytes and
    /// this yields plain `Int`s instead.
    private static func lineOffsets(in data: Data, into out: inout [Int]) {
        out.removeAll(keepingCapacity: true)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var searched = 0
            while searched < raw.count,
                  let hit = memchr(base + searched, 0x0A, raw.count - searched) {
                let idx = UnsafeRawPointer(hit) - base
                out.append(idx)
                searched = idx + 1
            }
        }
    }

    /// Whether the line spells `"usage"` anywhere.
    ///
    /// The test itself is documented above and stays; only its implementation changes.
    /// `Data.range(of:)` bridges to `NSData`'s Boyer-Moore for a 7-byte needle, which measured
    /// **261 of 3103 samples — 7% of the scan**. A `memchr` on the leading quote plus a `memcmp` is
    /// the same predicate at a fraction of the cost.
    private static func containsUsageKey(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let n = usageKeyBytes.count
            guard let base = raw.baseAddress, raw.count >= n else { return false }
            return usageKeyBytes.withUnsafeBufferPointer { needle -> Bool in
                var searched = 0
                // Only positions where a full needle could still fit are worth testing.
                while searched <= raw.count - n {
                    guard let hit = memchr(base + searched, Int32(needle[0]),
                                           raw.count - n - searched + 1) else { return false }
                    if memcmp(hit, needle.baseAddress!, n) == 0 { return true }
                    searched = (UnsafeRawPointer(hit) - base) + 1
                }
                return false
            }
        }
    }
}
