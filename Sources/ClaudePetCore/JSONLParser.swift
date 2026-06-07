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

    /// Parse one file into usage entries (one file held in memory at a time).
    /// Bad lines are skipped; a read error is thrown.
    public static func entries(inFileAt url: URL) throws -> [UsageEntry] {
        let data = try Data(contentsOf: url)
        var result: [UsageEntry] = []
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = entry(fromLineData: Data(slice)) {
                result.append(entry)
            }
        }
        return result
    }
}
