import Foundation

/// How much the reading can still be believed. Codex's percentage only moves when Codex itself
/// runs, so a figure can sit unchanged for days while looking exactly like a live one — the whole
/// point of this type is that the UI cannot render one without deciding which it has.
public enum CodexFreshness: Sendable, Equatable {
    case live       // under an hour old
    case stale      // an hour to a day
    case ancient    // over a day — old enough that the reset it names has probably already happened
}

/// One Codex rate-limit window (a 7-day one, and a 5-hour one again since at least 2026-10), read
/// from Codex's rollouts by `CodexRolloutReader` or from the terminal statusline's local cache.
public struct CodexLimit: Sendable, Equatable {
    public let windowMinutes: Int
    public let utilization: Double     // 0–100 %, Codex's own accounting
    public let resetsAt: Date
    /// When Codex reported this — **not** when the cache file was written. The file is rewritten
    /// every 60 seconds by any Claude Code session that renders a statusline; the number inside it
    /// only changes when Codex runs. On 2026-08-10 those two clocks were 65 hours apart.
    public let recordedAt: Date
    /// Tokens spent inside this window, or nil when the statusline could not work it out.
    ///
    /// Codex reports a percentage and never a count, so this is summed from the session rollouts by
    /// the statusline — not here. It is a **spend** figure and counts every token Codex was billed
    /// for, re-sent context included, so it is not the same measurement as the Claude row's
    /// transcript-derived count above it and the two should not be compared.
    ///
    /// `nil`, never 0, when unknown: the cache writes 0 for "could not tell", and a Codex row
    /// claiming zero tokens in a week it was plainly used is worse than one that stays quiet.
    public let tokensUsed: Int?
    /// The window this reading described has ended and Codex hasn't reported since. Set by
    /// `MetricsStore` via `asReset()`, never by a reader.
    public let hasReset: Bool

    public init(windowMinutes: Int, utilization: Double, resetsAt: Date, recordedAt: Date,
                tokensUsed: Int? = nil, hasReset: Bool = false) {
        self.windowMinutes = windowMinutes
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.recordedAt = recordedAt
        self.tokensUsed = tokensUsed
        self.hasReset = hasReset
    }

    /// This window once it has rolled over with no newer reading: 0%, and no token count — the
    /// count belonged to the window that ended. 0% rather than hidden because the window really is
    /// empty as far as this Mac knows (any Codex run here would have written a newer snapshot), and a
    /// row that vanishes reads as "Codex isn't installed". `recordedAt` is kept for "last used".
    public func asReset() -> CodexLimit {
        CodexLimit(windowMinutes: windowMinutes, utilization: 0, resetsAt: resetsAt,
                   recordedAt: recordedAt, tokensUsed: nil, hasReset: true)
    }

    public var fraction: Double { min(1, max(0, utilization / 100)) }

    /// Usable only while the window it describes hasn't rolled over — same rule as `ServerLimit`.
    /// Once `now >= resetsAt` the percentage belongs to a window that has already ended.
    public func isUsable(now: Date = Date()) -> Bool { now < resetsAt }

    /// Clamped at zero: a record stamped slightly in the future, or a clock that moved backwards,
    /// must not come out negative and read as fresher than live.
    public func age(now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(recordedAt)) }

    public func freshness(now: Date = Date()) -> CodexFreshness {
        let a = age(now: now)
        if a < 3600 { return .live }
        if a <= 86_400 { return .stale }
        return .ancient
    }
}

public enum CodexUsageReader {
    public static let defaultPath = "/tmp/claude/codex-usage-cache.tsv"

    /// Reads the statusline's Codex cache: one tab-separated row per window,
    /// `window_minutes, used_percent, resets_at, record_epoch[, tokens_used]`, the epochs plain
    /// integers rather than the ISO strings the Claude cache uses.
    ///
    /// The fifth field is optional on purpose. A statusline older than it writes four, and this has
    /// to keep working against that one rather than blanking the row until the shell script is
    /// updated — the two ship separately and always will.
    ///
    /// Returns `[]` for a missing, unreadable, or empty file, and skips any row that isn't wholly
    /// well-formed. A partial row is dropped rather than defaulted: a Codex bar reading 0% because a
    /// field failed to parse is worse than no bar, since nothing on screen would say so.
    ///
    /// Read whole rather than streamed — this file is a few dozen bytes. The 1 MB-chunk rule in
    /// `JSONLParser` is about 100 MB transcripts and does not apply here.
    public static func read(path: String = defaultPath) -> [CodexLimit] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var limits: [CodexLimit] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 4 || f.count == 5,
                  let window = Int(f[0]),
                  let pct = Double(f[1]),
                  let reset = Double(f[2]),
                  let recorded = Double(f[3]),
                  window > 0, pct >= 0 else { continue }
            // 0 and unparseable both mean "not known" — see `tokensUsed`.
            let tokens = f.count == 5 ? Int(f[4]).flatMap { $0 > 0 ? $0 : nil } : nil
            limits.append(CodexLimit(windowMinutes: window,
                                     utilization: pct,
                                     resetsAt: Date(timeIntervalSince1970: reset),
                                     recordedAt: Date(timeIntervalSince1970: recorded),
                                     tokensUsed: tokens))
        }
        // Short window first, matching how the Claude rows are ordered above it.
        return limits.sorted { $0.windowMinutes < $1.windowMinutes }
    }
}
