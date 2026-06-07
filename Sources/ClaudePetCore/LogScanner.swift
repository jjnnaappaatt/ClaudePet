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
    public func scan() -> [UsageEntry] {
        let files = Self.jsonlFiles(under: root)
        var present = Set<URL>()

        for url in files {
            present.insert(url)
            let (mtime, size) = Self.stat(url)
            if let hit = cache[url], hit.mtime == mtime, hit.size == size { continue }
            let entries = (try? JSONLParser.entries(inFileAt: url)) ?? []
            cache[url] = CachedFile(mtime: mtime, size: size, entries: entries)
        }
        // Forget files that disappeared.
        for url in cache.keys where !present.contains(url) { cache[url] = nil }

        return Self.merge(cache.values.flatMap(\.entries))
    }

    // MARK: - One-shot (no cache) — used for synchronous snapshot rendering.

    public static func scanOnce(root: URL = UsageScanner.defaultRoot) -> [UsageEntry] {
        let all = jsonlFiles(under: root).flatMap { (try? JSONLParser.entries(inFileAt: $0)) ?? [] }
        return merge(all)
    }

    // MARK: - Helpers

    static func merge(_ entries: [UsageEntry]) -> [UsageEntry] {
        // Sort by time so dedup keeps the earliest copy deterministically.
        Deduplicator.deduplicated(entries.sorted { $0.timestamp < $1.timestamp })
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

    static func stat(_ url: URL) -> (Date, Int) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
    }
}
