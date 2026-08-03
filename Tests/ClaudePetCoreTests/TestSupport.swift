import Foundation
@testable import ClaudePetCore

enum TestSupport {

    /// A statusline cache path that never exists.
    ///
    /// `MetricsStore.statuslineCachePath` defaults to the *real* `/tmp/claude/...` file, and the
    /// store now re-anchors its Auto budgets to whatever percentages it finds there. Without this,
    /// every budget assertion in the suite would depend on the developer's live Claude usage —
    /// passing or failing by time of day (it was masked only because the 5h window happened to be
    /// past its reset). Suites that *want* server data assign their own path after construction.
    static let noStatuslineCache = "/nonexistent/claudepet-tests/statusline-usage-cache.json"
    /// Same hazard for Claude Code's `/stats` cache: `statsCachePath` defaults to the real
    /// `~/.claude/stats-cache.json`, so a test asserting on those figures would read the developer's own
    /// lifetime usage.
    static let noStatsCache = "/nonexistent/claudepet-tests/stats-cache.json"

    /// Store wired away from BOTH real caches. Use this instead of `MetricsStore(defaults:)`.
    @MainActor
    static func store(defaults: UserDefaults) -> MetricsStore {
        let s = MetricsStore(defaults: defaults)
        s.statuslineCachePath = noStatuslineCache
        s.statsCachePath = noStatsCache
        return s
    }

    /// Build a usage entry with explicit fields for deterministic tests.
    static func entry(id: String = UUID().uuidString,
                      at date: Date,
                      model: String = "claude-opus-4-8",
                      input: Int = 0, output: Int = 0,
                      cacheRead: Int = 0, cw5m: Int = 0, cw1h: Int = 0,
                      sidechain: Bool = false,
                      project: String = "",
                      projectDir: String? = nil) -> UsageEntry {
        UsageEntry(messageID: MessageKey(hashing: id), timestamp: date, model: model,
                   family: ModelFamily(modelID: model),
                   inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                   cacheWrite5mTokens: cw5m, cacheWrite1hTokens: cw1h, isSidechain: sidechain,
                   // Default the directory to the cwd's own encoding — i.e. a session that ran in
                   // its project root, which is the ordinary case. Pass `projectDir` explicitly to
                   // model a turn in a subdirectory or a worktree.
                   project: project,
                   projectDir: projectDir ?? (project.isEmpty ? "" : ProjectKey.encode(project)))
    }
}
