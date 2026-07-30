import Foundation

/// Maps transcripts to the project they belong to, and recovers each project's real path.
///
/// Two facts about `~/.claude/projects`, both measured rather than assumed:
///
/// 1. **`cwd` alone is far too fine-grained to group by.** It's the working directory of the
///    individual turn, so on real data 120 distinct values collapsed to just 11 projects. The tail is
///    workflow worktrees (`<project>/.claude/worktrees/wf_…` — around 90 of them) and incidental
///    subdirectories (`audit-dashboard/node_modules/lucide-react/dist/esm/icons`). Grouping by `cwd`
///    turns "which projects burned my tokens" into an unreadable list.
///
/// 2. **The containing directory name is the exact grouping key**, because Claude Code derives it
///    from the session's original cwd — every subdirectory, worktree and subagent of a session writes
///    beneath that one directory.
///
/// The catch is that the encoding is lossy (see `encode`), so the directory name can't be turned back
/// into a path. It can, however, be *checked*: re-encode each `cwd` seen in the group and keep the one
/// that reproduces the directory name. On real data that resolved 11 of 11 projects exactly — and it
/// matters, because the obvious alternatives are wrong. Picking the most frequent `cwd` would have
/// labelled `-Users-napat` as "ClaudePet" and `-Users-napat-Desktop-AAI` as "aai_next_dashboard",
/// since most turns in those projects ran in a subdirectory.
public enum ProjectKey {

    /// Claude Code's own directory encoding: every character that isn't alphanumeric becomes `-`.
    /// Verified against all 15 project directories on disk against the real paths in `~/.claude.json`
    /// — including `/Users/napat/Desktop/LiDAR + HPE` → `-Users-napat-Desktop-LiDAR---HPE`, where the
    /// space, the `+` and the second space each contribute one dash.
    ///
    /// Lossy and NOT invertible: `-` and `_` and ` ` and `/` all encode to `-`.
    public static func encode(_ path: String) -> String {
        String(path.map { c in
            (c.isASCII && (c.isLetter || c.isNumber)) ? c : "-"
        })
    }

    /// The project's real absolute path, given its directory name and every `cwd` observed under it
    /// (with how often each appeared).
    ///
    /// Prefers the `cwd` that re-encodes to `dir` — that is the session's original directory, exactly.
    /// Falls back to the shallowest observed path when no turn ever ran in the project root itself,
    /// with a deterministic tie-break so a label can never flicker between runs.
    public static func resolveRoot(dir: String, cwdCounts: [String: Int]) -> String {
        guard !cwdCounts.isEmpty else { return "" }
        if let exact = cwdCounts.keys.sorted().first(where: { encode($0) == dir }) { return exact }
        return cwdCounts.keys.min { a, b in
            a.count != b.count ? a.count < b.count : a < b
        } ?? ""
    }
}
