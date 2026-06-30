import Foundation

/// Decodes line-delimited transcript files into normalized `UsageEntry` values.
/// Skips every line that isn't a real, priced assistant turn.
public enum JSONLParser {

    private static let decoder = JSONDecoder()

    /// Decode a single JSONL line. Returns nil for non-usage lines
    /// (user/file-history/permission-mode/synthetic, or undecodable).
    public static func entry(fromLineData data: Data) -> UsageEntry? {
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

        return UsageEntry(
            messageID: messageID,
            timestamp: timestamp,
            model: model,
            family: ModelFamily(modelID: model),
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0,
            cacheWrite5mTokens: cw5m,
            cacheWrite1hTokens: cw1h,
            isSidechain: record.isSidechain ?? false
        )
    }

    /// Convenience for tests / fixtures.
    public static func entry(fromLine line: String) -> UsageEntry? {
        entry(fromLineData: Data(line.utf8))
    }

    /// Parse one file into usage entries, streaming it in fixed chunks so peak memory is
    /// ~one chunk plus the longest line — never the whole file. (Transcripts reach 100 MB+;
    /// `Data(contentsOf:)` would spike RSS that much on every re-read.) Bad lines are
    /// skipped; a read error is thrown.
    public static func entries(inFileAt url: URL) throws -> [UsageEntry] {
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
                let complete = buffer.subdata(in: buffer.startIndex..<lastNewline)
                for slice in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    if let entry = entry(fromLineData: Data(slice)) {
                        result.append(entry)
                    }
                }
                buffer = buffer.subdata(in: buffer.index(after: lastNewline)..<buffer.endIndex)   // compact tail
            }
        }
        // A final line with no trailing newline.
        if !buffer.isEmpty, let entry = entry(fromLineData: buffer) {
            result.append(entry)
        }
        return result
    }
}
