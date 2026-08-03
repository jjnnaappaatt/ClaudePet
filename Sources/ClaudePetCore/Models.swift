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

// MARK: - Message key

/// The dedup key, as 128 bits instead of a string.
///
/// `messageID` is unique per entry by construction, so — unlike `model` and `cwd` — interning it
/// cannot help: 128k distinct values means 128k allocations however you store them. Measured, each
/// one is a 28-character `String` (`"msg_01J3a4M2WvUVmAuX7RXpZkXU"`), past Swift's 15-byte inline
/// limit, so it heap-allocates into the 64-byte malloc class: **129,692 `StringStorage` nodes,
/// 8.3 MB**, purely to be compared for equality and then never read.
///
/// Hashing it to two `UInt64`s is the same 16 bytes inside `UsageEntry` but **zero heap and zero
/// malloc nodes**. Nothing ever needs the original text back: the only readers are the two dedup
/// `Set`s (`UsageScanner.merge`, `Deduplicator`).
///
/// **128 bits, not 64, because a collision here is silent and load-bearing.** Dedup keeps the first
/// entry per key, so two distinct IDs colliding would *drop a real turn* — the same class of error
/// CLAUDE.md warns tripling comes from, in the other direction. At 64 bits the birthday probability
/// over 128k keys is ~4e-10; at 128 bits it is ~1e-29, i.e. never. The extra 8 bytes are free anyway,
/// since `String` was 16 bytes too — this change buys heap, not stride.
///
/// Two independent lanes, not one hash split in half: deriving both from a single 64-bit value would
/// carry only 64 bits of entropy and collide exactly as often as the 64-bit version.
public struct MessageKey: Hashable, Sendable {
    private let lo: UInt64
    private let hi: UInt64

    public init(hashing s: String) {
        var a: UInt64 = 0xCBF2_9CE4_8422_2325          // FNV-1a 64 offset basis
        var b: UInt64 = 0x9E37_79B9_7F4A_7C15          // a different basis for the second lane
        for byte in s.utf8 {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            b = (b ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            b = b &+ 0x165667B19E3779F9                 // break the lanes' symmetry every round
        }
        lo = Self.avalanche(a)
        hi = Self.avalanche(b)
    }

    /// splitmix64's finalizer — cheap, and it spreads FNV's weak high bits across the whole word.
    private static func avalanche(_ x: UInt64) -> UInt64 {
        var h = x
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        return h ^ (h >> 31)
    }
}

// MARK: - Normalized usage entry (post-parse, pre-dedup)

/// One de-noised assistant turn's token usage. `messageID` is the dedup key.
///
/// **Field order and integer widths here are load-bearing, not style.** Two copies of this struct
/// are resident for the life of the process — `UsageScanner.cache` (per file) and
/// `MetricsStore.lastEntries` (merged) — at ~128k entries each, so every byte costs ~250 KB twice
/// over. Declared in the obvious order with `Int` counts it measured **128 bytes**, of which 14 were
/// pure alignment padding: `family` (1 byte) and `isSidechain` (1 byte) each sat between 8-aligned
/// fields and each dragged 7 bytes of hole behind it.
///
/// Grouping the two 1-byte fields together at the end and narrowing the five counts to `Int32`
/// brings it to **96 bytes**, a 25% cut, with no change to any figure. `ArtDistinctnessTests` has an
/// equivalent for the mascot; this one is pinned by `AllocationTests.usageEntryStaysCompact`, because
/// nothing else in the suite can see the layout regress.
public struct UsageEntry: Sendable, Equatable, Identifiable {
    // 16-byte, 8-aligned fields first, then the 4-byte counts, then the two 1-byte fields last.
    public let messageID: MessageKey
    public let timestamp: Date
    public let model: String
    /// The turn's own working directory (`cwd`), or "" when the line didn't carry one. This is the
    /// only exact source of a project's real *name*, but it is NOT the grouping key — it varies per
    /// turn across subdirectories and workflow worktrees (120 values for 11 projects on real data).
    public let project: String
    /// The `~/.claude/projects/<dir>` folder this transcript lives under — the exact grouping key,
    /// since Claude Code derives it from the session's original cwd. See `ProjectKey`.
    public let projectDir: String

    /// **Stored as `Int32`, read as `Int`.** A single turn's counts are thousands to low millions;
    /// `Int32` tops out at 2.1 billion, so the width is never the binding constraint on one entry —
    /// but it halves 40 bytes to 20 across every resident copy. The accessors below keep the public
    /// surface `Int`, so no caller, keypath or test had to change, and the sums they feed (which
    /// genuinely can exceed `Int32`) are computed in `Int`.
    private let _inputTokens: Int32
    private let _outputTokens: Int32
    private let _cacheReadTokens: Int32
    private let _cacheWrite5mTokens: Int32
    private let _cacheWrite1hTokens: Int32

    public let family: ModelFamily
    public let isSidechain: Bool

    public var inputTokens: Int { Int(_inputTokens) }
    public var outputTokens: Int { Int(_outputTokens) }
    public var cacheReadTokens: Int { Int(_cacheReadTokens) }
    public var cacheWrite5mTokens: Int { Int(_cacheWrite5mTokens) }
    public var cacheWrite1hTokens: Int { Int(_cacheWrite1hTokens) }

    public var id: MessageKey { messageID }

    /// Human-scale "work" tokens.
    public var workTokens: Int { inputTokens + outputTokens }

    /// Total billable tokens (incl. cache read + writes).
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    /// Counts arrive as `Int` and are clamped, never truncated. A value past `Int32.max` can only
    /// come from a corrupt line, and saturating there keeps that one entry visibly huge rather than
    /// wrapping it negative and quietly subtracting from a total.
    public init(messageID: MessageKey, timestamp: Date, model: String, family: ModelFamily,
                inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheWrite5mTokens: Int, cacheWrite1hTokens: Int, isSidechain: Bool,
                project: String = "", projectDir: String = "") {
        self.messageID = messageID
        self.timestamp = timestamp
        self.model = model
        self.project = project
        self.projectDir = projectDir
        self._inputTokens = Self.narrow(inputTokens)
        self._outputTokens = Self.narrow(outputTokens)
        self._cacheReadTokens = Self.narrow(cacheReadTokens)
        self._cacheWrite5mTokens = Self.narrow(cacheWrite5mTokens)
        self._cacheWrite1hTokens = Self.narrow(cacheWrite1hTokens)
        self.family = family
        self.isSidechain = isSidechain
    }

    private static func narrow(_ v: Int) -> Int32 {
        Int32(clamping: v)
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
