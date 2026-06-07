import Foundation

// MARK: - Raw JSONL decoding (one object per line)

/// A single line of a `~/.claude/projects/**/*.jsonl` transcript.
/// Only `type == "assistant"` lines carry token usage; `timestamp`/`requestId`/
/// `isSidechain` are TOP-LEVEL (not under `message`).
struct LogRecord: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let isSidechain: Bool?
    let message: RawMessage?
}

struct RawMessage: Decodable {
    let id: String?
    let model: String?
    let usage: RawUsage?
}

struct RawUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_read_input_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_creation: RawCacheCreation?
}

/// Cache-write tokens split by TTL — 5-minute writes bill at 1.25×, 1-hour at 2× input.
struct RawCacheCreation: Decodable {
    let ephemeral_5m_input_tokens: Int?
    let ephemeral_1h_input_tokens: Int?
}

// MARK: - Budget unit

/// What the 5-hour gauge (and its budget) is measured in. Switchable in Settings.
public enum BudgetUnit: String, Codable, Sendable, CaseIterable {
    case tokens
    case usd
}

// MARK: - Model family

public enum ModelFamily: String, Sendable, CaseIterable {
    case opus, sonnet, haiku, other

    public init(modelID: String) {
        let m = modelID.lowercased()
        if m.contains("opus") { self = .opus }
        else if m.contains("sonnet") { self = .sonnet }
        else if m.contains("haiku") { self = .haiku }
        else { self = .other }
    }

    public var displayName: String {
        switch self {
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        case .other: return "Other"
        }
    }
}

// MARK: - Normalized usage entry (post-parse, pre-dedup)

/// One de-noised assistant turn's token usage. `messageID` is the dedup key.
public struct UsageEntry: Sendable, Equatable, Identifiable {
    public let messageID: String
    public let timestamp: Date
    public let model: String
    public let family: ModelFamily
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWrite5mTokens: Int
    public let cacheWrite1hTokens: Int
    public let isSidechain: Bool

    public var id: String { messageID }

    /// Human-scale "work" tokens.
    public var workTokens: Int { inputTokens + outputTokens }

    /// Total billable tokens (incl. cache read + writes).
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    public init(messageID: String, timestamp: Date, model: String, family: ModelFamily,
                inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheWrite5mTokens: Int, cacheWrite1hTokens: Int, isSidechain: Bool) {
        self.messageID = messageID
        self.timestamp = timestamp
        self.model = model
        self.family = family
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.isSidechain = isSidechain
    }
}

// MARK: - Timestamp parsing

/// Parses ISO8601 timestamps that may or may not carry fractional seconds.
enum TimestampParser {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
