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
    private struct CachedFile {
        let mtime: Date
        let size: Int
        /// Byte offset this file has been parsed up to — where a resumed parse starts.
        let parsedUpTo: UInt64
        /// Fingerprint of the bytes immediately before `parsedUpTo`, so a rewritten or truncated
        /// file cannot be mistaken for an appended one.
        let boundaryHash: UInt64
        /// Trailing entries that came from a line with no newline yet; dropped before appending.
        let tailCount: Int
        let entries: [UsageEntry]
    }
    private var cache: [URL: CachedFile] = [:]

    /// Kept on the actor rather than per-scan, **because entries now outlive the scan that parsed
    /// them.** Its doc comment used to say the opposite, and that was right while every changed file
    /// was re-parsed whole: the table existed only to stop 250k allocations inside one pass. With
    /// incremental appends, a file's head is parsed by one scan and its tail by hundreds of later
    /// ones, so a per-scan table would hand out a fresh `String` for the same model id on every
    /// append and the sharing would decay as the app ran. It holds ~130 distinct values, all of
    /// which the entries retain anyway, so keeping it costs the dictionary and nothing else.
    private let interner = StringInterner()

    /// How the last scan split its work: files read whole vs files resumed from an offset.
    ///
    /// These exist because the incremental path is **invisible from its output** — a resumed parse
    /// and a full re-parse produce identical entries, so every functional test in the suite passes
    /// either way and the only symptom of losing it is the app going back to burning a core. Same
    /// reasoning as `AllocationTests`: when correctness can't see a regression, something else has to.
    public private(set) var lastScanFullParses = 0
    public private(set) var lastScanTailParses = 0

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
        lastScanFullParses = 0
        lastScanTailParses = 0

        for url in files {
            present.insert(url)
            let (mtime, size) = Self.stat(url)
            if let hit = cache[url], hit.mtime == mtime, hit.size == size { continue }
            let dir = Self.projectDir(of: url, under: root)

            // The file only grew and the bytes we stopped at are untouched: parse just the tail.
            //
            // This is the difference between a widget that idles and one that pins a core. The key
            // is `(mtime, size)`, so an appended line invalidates the whole file — and transcripts
            // are append-only and reach hundreds of MB, so one new line was costing a 180 MB or
            // 682 MB re-read. The guard is one-directional in the same way the `"usage"` probe is:
            // a mismatch costs exactly the old behaviour, and a false match would need a 4 KB
            // collision. Truncation and rotation land on the mismatch side; compaction turned out
            // to append rather than rewrite, but is not relied on for correctness.
            //
            // `size >= hit.size` is a cheap early-out, NOT the truncation guard, and mutation
            // testing says so: deleting it leaves every test green, because a file shorter than
            // `parsedUpTo` cannot produce a fingerprint there (the read comes up short and returns
            // nil). It survives only to skip opening the file at all in the shrink case. The
            // fingerprint is what makes this safe — do not let this line take the credit for it.
            if let hit = cache.removeValue(forKey: url) {
                if size >= hit.size, hit.parsedUpTo > 0,
                   let fingerprint = Self.boundaryHash(of: url, endingAt: hit.parsedUpTo),
                   fingerprint == hit.boundaryHash,
                   let tail = autoreleasepool(invoking: {
                       try? JSONLParser.parse(fileAt: url, from: hit.parsedUpTo,
                                              projectDir: dir, interner: interner)
                   }) {
                    // `hit` was removed from the dictionary above, so this array is uniquely
                    // referenced and the append is in place rather than a copy of the whole file.
                    var entries = hit.entries
                    if hit.tailCount > 0 { entries.removeLast(min(hit.tailCount, entries.count)) }
                    entries.append(contentsOf: tail.entries)
                    cache[url] = CachedFile(
                        mtime: mtime, size: size, parsedUpTo: tail.parsedUpTo,
                        boundaryHash: Self.boundaryHash(of: url, endingAt: tail.parsedUpTo) ?? 0,
                        tailCount: tail.tailCount, entries: entries)
                    lastScanTailParses += 1
                    continue
                }
                // Fell through: put the old parse back so a failed read below can't lose it.
                cache[url] = hit
            }

            // Drain the parse temporaries per file so a big rescan doesn't balloon the peak.
            //
            // A read failure must NOT be cached. The key is (mtime, size), and a completed
            // subagent transcript is write-once — its key never changes again, so a cached `[]`
            // would zero that file for the life of the process, silently and unrecoverably.
            // `present` already holds this URL (inserted above), so skipping here leaves any
            // prior good parse intact and un-evicted; the next scan retries the read.
            // (Explicit `invoking:` label — a trailing closure here would be parsed as the
            // guard's else-body.)
            guard let parsed = autoreleasepool(invoking: {
                try? JSONLParser.parse(fileAt: url, from: 0, projectDir: dir, interner: interner)
            }) else { continue }
            cache[url] = CachedFile(
                mtime: mtime, size: size, parsedUpTo: parsed.parsedUpTo,
                boundaryHash: Self.boundaryHash(of: url, endingAt: parsed.parsedUpTo) ?? 0,
                tailCount: parsed.tailCount, entries: parsed.entries)
            lastScanFullParses += 1
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

    /// `consuming`, and that keyword is the whole point.
    ///
    /// The intent below was always to sort in place — the caller hands over a fresh concatenation
    /// that nobody else wants. But a plain parameter is *borrowed*: the caller's temporary stays live
    /// for the duration of the call, so `var sorted = entries` made the buffer non-uniquely
    /// referenced and `sort()` silently took a full copy-on-write copy anyway. The comment claimed
    /// one allocation; the code made two.
    ///
    /// On a real 128k-entry corpus that copy is ~15.7 MB, allocated and freed on **every scan** —
    /// and FSEvents rescans on every transcript write. `vmmap` showed the residue as empty
    /// `MALLOC_LARGE` regions of exactly that size, several of them, holding ~100 MB dirty.
    /// `consuming` transfers ownership so the buffer is uniquely referenced and the sort is genuinely
    /// in place.
    static func merge(_ entries: consuming [UsageEntry], deduplicated: Bool = true) -> [UsageEntry] {
        var sorted = consume entries
        sorted.sort { $0.timestamp < $1.timestamp }
        guard deduplicated else { return sorted }
        // In place, not `filter`. `Deduplicator.deduplicated` returns a NEW array, so at the moment
        // it returned there were two full copies live; `removeAll(where:)` compacts the one we
        // already own. Same earliest-wins semantics — `removeAll(where:)` visits in order.
        var seen = Set<MessageKey>()
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

    /// FNV-1a over the last ≤4 KB ending at `offset` — the guard that makes resuming safe.
    ///
    /// Deterministic on purpose: Swift's `Hasher` is randomly seeded per process, and while this
    /// cache never outlives the process today, a fingerprint that silently means something different
    /// on the next launch is a trap to leave lying around.
    ///
    /// It proves the bytes we stopped reading at are still the bytes that are there. A truncated,
    /// rotated or rewritten file fails it and takes the full-parse path — the same work the app did
    /// before any of this existed, so being wrong here costs speed and never correctness. Returns nil
    /// for `offset == 0` (nothing has been consumed, so there is nothing to vouch for), which keeps
    /// an empty or newline-free file on the full path forever.
    static func boundaryHash(of url: URL, endingAt offset: UInt64) -> UInt64? {
        guard offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let window = min(offset, 4096)
        guard (try? handle.seek(toOffset: offset - window)) != nil,
              let bytes = try? handle.read(upToCount: Int(window)),
              bytes.count == Int(window) else { return nil }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        bytes.withUnsafeBytes { raw in
            for b in raw { hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        }
        return hash
    }

    static func stat(_ url: URL) -> (Date, Int) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
    }
}
