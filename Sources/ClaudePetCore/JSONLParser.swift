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
    private static let usageKey = Data(#""usage""#.utf8)

    public static func entries(inFileAt url: URL, projectDir: String = "",
                               interner: StringInterner? = nil) throws -> [UsageEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var result: [UsageEntry] = []
        var buffer = Data()
        let chunkSize = 1 << 20   // 1 MB

        while case let chunk = handle.readData(ofLength: chunkSize), !chunk.isEmpty {
            // Drain per chunk: JSON decoding spins off many autoreleased Foundation
            // temporaries; without this they pile up to a huge peak over a 100 MB+ file.
            autoreleasepool {
                buffer.append(chunk)
                // Process every complete line in the buffer; carry the trailing partial line.
                guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return }
                // Slices, not `subdata`. `Data.SubSequence` IS `Data`, so both of these copies were
                // pure overhead: one of the whole chunk, then one per line. On a 1.9 GB corpus that
                // was roughly 4 GB of transient copying for no gain — `JSONDecoder` accepts a slice
                // with a non-zero start index perfectly well.
                let complete = buffer[buffer.startIndex..<lastNewline]
                for slice in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    guard slice.range(of: usageKey) != nil else { continue }
                    if let entry = entry(fromLineData: slice, projectDir: projectDir,
                                         interner: interner) {
                        result.append(entry)
                    }
                }
                buffer = buffer.subdata(in: buffer.index(after: lastNewline)..<buffer.endIndex)   // compact tail
            }
        }
        // A final line with no trailing newline.
        if !buffer.isEmpty, buffer.range(of: usageKey) != nil,
           let entry = entry(fromLineData: buffer, projectDir: projectDir, interner: interner) {
            result.append(entry)
        }
        return result
    }
}
