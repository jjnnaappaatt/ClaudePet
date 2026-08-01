import Foundation

/// Scans `~/.claude/projects/**/*.jsonl` (including `subagents/agent-*.jsonl`) and
/// returns the globally-deduplicated usage entries. Caches per-file results keyed by
/// (mtime, size) so re-scans only re-parse changed files.
public actor UsageScanner {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private let root: URL
    private struct CachedFile { let mtime: Date; let size: Int; let entries: [UsageEntry] }
    private var cache: [URL: CachedFile] = [:]

    public init(root: URL = UsageScanner.defaultRoot) {
        self.root = root
    }

    /// Incremental scan: parse only new/changed files, drop deleted ones, return
    /// all entries deduplicated globally (earliest occurrence wins).
    ///
    /// `deduplicated: false` keeps every logged line instead, which reproduces Claude Code's
    /// `/stats` counting. Only the merge step changes — the per-file parse cache is shared — so
    /// flipping the mode costs a re-merge, never a re-read.
    public func scan(deduplicated: Bool = true) -> [UsageEntry] {
        let files = Self.jsonlFiles(under: root)
        var present = Set<URL>()
        // One table for the whole scan, so `model` and `cwd` are shared across FILES and not merely
        // within one. Held locally rather than on the actor: it exists to stop 250k allocations
        // being made, not to be kept afterwards, and the strings it hands out are retained by the
        // entries themselves.
        let interner = StringInterner()

        for url in files {
            present.insert(url)
            let (mtime, size) = Self.stat(url)
            if let hit = cache[url], hit.mtime == mtime, hit.size == size { continue }
            // Drain the parse temporaries per file so a big rescan doesn't balloon the peak.
            //
            // A read failure must NOT be cached. The key is (mtime, size), and a completed
            // subagent transcript is write-once — its key never changes again, so a cached `[]`
            // would zero that file for the life of the process, silently and unrecoverably.
            // `present` already holds this URL (inserted above), so skipping here leaves any
            // prior good parse intact and un-evicted; the next scan retries the read.
            // (Explicit `invoking:` label — a trailing closure here would be parsed as the
            // guard's else-body.)
            let dir = Self.projectDir(of: url, under: root)
            guard let entries = autoreleasepool(invoking: {
                try? JSONLParser.entries(inFileAt: url, projectDir: dir, interner: interner)
            }) else { continue }
            cache[url] = CachedFile(mtime: mtime, size: size, entries: entries)
        }
        // Forget files that disappeared.
        for url in cache.keys where !present.contains(url) { cache[url] = nil }

        return Self.merge(Self.concatenated(cache.values), deduplicated: deduplicated)
    }

    // MARK: - One-shot (no cache) — used for synchronous snapshot rendering.

    public static func scanOnce(root: URL = UsageScanner.defaultRoot,
                                deduplicated: Bool = true) -> [UsageEntry] {
        let interner = StringInterner()
        var all: [UsageEntry] = []
        for url in jsonlFiles(under: root) {
            // Per-file `autoreleasepool`, the same as the actor path — and for the same measured
            // reason. It was missing here, so every snapshot render (`CLAUDEPET_DASHBOARD`,
            // `CLAUDEPET_SNAPSHOT`) held the Foundation temporaries of all 2,229 files at once.
            let dir = projectDir(of: url, under: root)
            autoreleasepool {
                if let e = try? JSONLParser.entries(inFileAt: url, projectDir: dir,
                                                    interner: interner) {
                    all.append(contentsOf: e)
                }
            }
        }
        return merge(all, deduplicated: deduplicated)
    }

    // MARK: - Helpers

    /// One array, sized once.
    ///
    /// `flatMap` grows geometrically, so building ~125k entries reallocated the backing store a
    /// dozen times and left the previous buffer live at each doubling — a transient of roughly the
    /// final size on top of the final size. Counting first costs one cheap pass over the values.
    private static func concatenated(_ files: some Collection<CachedFile>) -> [UsageEntry] {
        var out: [UsageEntry] = []
        out.reserveCapacity(files.reduce(0) { $0 + $1.entries.count })
        for f in files { out.append(contentsOf: f.entries) }
        return out
    }

    static func merge(_ entries: [UsageEntry], deduplicated: Bool = true) -> [UsageEntry] {
        // Sort by time so dedup keeps the earliest copy deterministically. Sort in place
        // (the caller's array is a fresh concatenation) to avoid a second full-set copy.
        var sorted = entries
        sorted.sort { $0.timestamp < $1.timestamp }
        guard deduplicated else { return sorted }
        // In place, not `filter`. `Deduplicator.deduplicated` returns a NEW array, so at the moment
        // it returned there were two full copies live; `removeAll(where:)` compacts the one we
        // already own. Same earliest-wins semantics — `removeAll(where:)` visits in order.
        var seen = Set<String>()
        seen.reserveCapacity(sorted.count)
        sorted.removeAll { !seen.insert($0.messageID).inserted }
        return sorted
    }

    static func jsonlFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            out.append(url)
        }
        return out
    }

    /// The single path component directly under `root` — i.e. `~/.claude/projects/<this>/…`.
    ///
    /// It has to be the component under the root rather than the file's own parent directory: a
    /// session's own transcript sits at `<project>/<session>.jsonl`, but its subagents sit deeper, at
    /// `<project>/<session>/subagents/agent-*.jsonl`. Taking the parent would scatter one project
    /// across a directory per session. Returns "" for a file that isn't under `root` at all.
    static func projectDir(of url: URL, under root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts
        else { return "" }
        return parts[rootParts.count]
    }

    static func stat(_ url: URL) -> (Date, Int) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
    }
}
