import Foundation

// MARK: - Raw JSONL decoding (one object per line)

/// A single line of a `~/.claude/projects/**/*.jsonl` transcript.
/// Only `type == "assistant"` lines carry token usage; `timestamp`/`requestId`/
/// `isSidechain`/`cwd` are TOP-LEVEL (not under `message`).
struct LogRecord: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let isSidechain: Bool?
    /// The project directory the turn ran in, as a real absolute path — this is the ONLY reliable
    /// source of project identity. The containing `~/.claude/projects/<dir>` name is a lossy encoding
    /// (every non-alphanumeric becomes `-`, so `/Users/x/Desktop/LiDAR + HPE` →
    /// `-Users-x-Desktop-LiDAR---HPE`) and cannot be decoded back. Audited across 400 transcripts:
    /// 12,244 assistant lines carried `cwd`, 0 did not — so no fallback machinery is needed. The
    /// only files lacking it are `subagents/workflows/**/journal.jsonl`, which carry no usage at all.
    let cwd: String?
    let message: RawMessage?
}

struct RawMessage: Decodable {
    let id: String?
    let model: String?
    let usage: RawUsage?
}

/// The five fields below are ALL of the token-bearing ones — audited against 33k real assistant
/// turns, so the rest are deliberate omissions rather than oversights:
/// - `server_tool_use` is `{web_search_requests, web_fetch_requests}` — request *counts*, billed
///   per request, and the fetched text is already inside `input_tokens`. Folding it into
///   `totalTokens` would be a category error. (Every observed occurrence was also zero.)
/// - `iterations[]` is a per-iteration breakdown that duplicates these totals — it matched the
///   top level on 31,805 of 31,806 turns, so summing it would roughly double-count.
/// - `service_tier`, `inference_geo`, `speed` are strings.
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

/// Whether per-day/hour/model token figures show "work" (input+output only) or cache-inclusive
/// "total" (work + cache reads + cache writes). Display-only — aggregates always carry both, and
/// cost ($) is cache-inclusive regardless. Default is `.total` so the numbers reflect the tokens
/// Claude actually processes (work alone is ~1% of that under always-on prompt caching).
public enum TokenBasis: String, Codable, Sendable, CaseIterable {
    case work
    case total
}

// MARK: - Model family

public enum ModelFamily: String, Sendable, CaseIterable {
    case fable, opus, sonnet, haiku, other

    public init(modelID: String) {
        let m = modelID.lowercased()
        // Mythos shares Fable's specs and pricing (Project Glasswing), so price it as Fable.
        if m.contains("fable") || m.contains("mythos") { self = .fable }
        else if m.contains("opus") { self = .opus }
        else if m.contains("sonnet") { self = .sonnet }
        else if m.contains("haiku") { self = .haiku }
        else { self = .other }
    }

    public var displayName: String {
        switch self {
        case .fable: return "Fable"
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
    /// The turn's own working directory (`cwd`), or "" when the line didn't carry one. This is the
    /// only exact source of a project's real *name*, but it is NOT the grouping key — it varies per
    /// turn across subdirectories and workflow worktrees (120 values for 11 projects on real data).
    public let project: String
    /// The `~/.claude/projects/<dir>` folder this transcript lives under — the exact grouping key,
    /// since Claude Code derives it from the session's original cwd. See `ProjectKey`.
    ///
    /// These two stay LAST, with defaulted init parameters, so every existing call site keeps
    /// compiling — same reasoning as `Totals`' sidechain fields.
    public let projectDir: String

    public var id: String { messageID }

    /// Human-scale "work" tokens.
    public var workTokens: Int { inputTokens + outputTokens }

    /// Total billable tokens (incl. cache read + writes).
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    public init(messageID: String, timestamp: Date, model: String, family: ModelFamily,
                inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheWrite5mTokens: Int, cacheWrite1hTokens: Int, isSidechain: Bool,
                project: String = "", projectDir: String = "") {
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
        self.project = project
        self.projectDir = projectDir
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
