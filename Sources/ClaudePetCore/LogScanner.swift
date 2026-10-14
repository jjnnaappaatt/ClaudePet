import Foundation

/// What changed on disk since the last scan, as reported by `FileWatcher`.
public enum FileChanges: Sendable, Equatable {
    /// Walk the whole tree — first scan, dropped events, a directory created/moved/removed, or
    /// the periodic safety rescan.
    case everything
    /// Just these files (absolute paths, as FSEvents spells them). Non-`.jsonl` paths are ignored.
    case paths(Set<String>)

    public func merged(with other: FileChanges) -> FileChanges {
        switch (self, other) {
        case let (.paths(a), .paths(b)): return .paths(a.union(b))
        default: return .everything
        }
    }
}

/// The result of `UsageScanner.scanChanges`, relative to the previous result it delivered.
public enum ScanDelta: Sendable {
    /// Nothing that affects the merged entries.
    case unchanged
    /// New entries, sorted by timestamp and deduplicated against everything delivered before, plus
    /// `repeats`: further copies of messages already delivered, which may carry larger usage (a
    /// response's later streaming snapshot). New entries may interleave with the tail of the previous
    /// result (two sessions writing at once), so the caller merges rather than appends blindly — see
    /// `UsageScanner.mergeAppended(_:repeats:into:)`.
    case appended([UsageEntry], repeats: [UsageEntry])
    /// The complete merged history; discard what you had.
    case full([UsageEntry])
}

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
    /// Keyed by standardized **path**, not `URL`: a path from an FSEvents callback and a URL from
    /// the directory enumerator must land on the same key, and `URL` equality compares spellings.
    private var cache: [String: CachedFile] = [:]

    // State of the last result handed out, so the next one can be a delta against it.
    //
    // **This is why a busy session no longer costs a full sort per write.** Every scan used to
    // concatenate all ~130k cached entries, sort them and rebuild the dedup set, to absorb the
    // handful of lines one append added — `UsageScanner.merge` was the single largest block of
    // samples in a live profile of the widget pinned at 100% of a core. The key set costs ~4 MB
    // resident (16-byte keys, power-of-two capacity); it used to be built and dropped every scan.
    /// `deduplicated` flag of the last delivered result; nil until one has been delivered.
    private var baseMode: Bool?
    /// Keys of every entry in the last delivered result (dedup mode only).
    private var baseKeys = Set<MessageKey>()

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
    ///
    /// Always walks the whole tree and returns the full merge; `scanChanges` is the live path.
    public func scan(deduplicated: Bool = true) -> [UsageEntry] {
        _ = update(Self.jsonlFiles(under: root).map(Self.key), walkedAll: true)
        return fullMerge(deduplicated: deduplicated)
    }

    /// The live path: look only at `changes`, and answer with a delta against the previous result
    /// whenever the change was purely additive.
    ///
    /// Falls back to `.full` whenever entries the caller already holds could be wrong — a file
    /// re-parsed from the start, a dropped partial line, a deleted file, or a mode flip. Each of
    /// those is rare; the common case, lines appended to live transcripts, is answered without
    /// touching the other ~130k entries. A further copy of a delivered message comes back in
    /// `repeats` for `mergeAppended` to fold in (see `UsageEntry.absorbing`).
    public func scanChanges(deduplicated: Bool, changes: FileChanges) -> ScanDelta {
        let (fresh, invalidated): ([UsageEntry], Bool)
        switch changes {
        case .everything:
            (fresh, invalidated) = update(Self.jsonlFiles(under: root).map(Self.key), walkedAll: true)
        case .paths(let paths):
            (fresh, invalidated) = update(paths.compactMap(inRoot), walkedAll: false)
        }
        if invalidated || baseMode != deduplicated {
            return .full(fullMerge(deduplicated: deduplicated))
        }
        guard !fresh.isEmpty else { return .unchanged }
        var batch = fresh
        batch.sort { $0.timestamp < $1.timestamp }
        guard deduplicated else { return .appended(batch, repeats: []) }
        // A key already delivered is another snapshot of a response the caller holds. It goes back
        // as a repeat for the caller to fold in where the entry sits — not as a reason to re-merge:
        // streaming writes several copies of every response, so a `.full` here would put the
        // whole-history merge back on nearly every write.
        var kept: [UsageEntry] = []
        var repeats: [UsageEntry] = []
        kept.reserveCapacity(batch.count)
        for e in batch {
            if baseKeys.insert(e.messageID).inserted { kept.append(e) } else { repeats.append(e) }
        }
        return .appended(kept, repeats: repeats)
    }

    /// The full merge of everything cached, recorded as the new base for deltas.
    private func fullMerge(deduplicated: Bool) -> [UsageEntry] {
        let merged = Self.merge(Self.concatenated(cache.values), deduplicated: deduplicated,
                                keys: &baseKeys)
        baseMode = deduplicated
        return merged
    }

    /// Bring the parse cache up to date for `paths`. Returns the entries that are new since the
    /// last call, and whether anything already handed out was removed or replaced (which a delta
    /// can't express).
    private func update(_ paths: [String], walkedAll: Bool) -> (fresh: [UsageEntry], invalidated: Bool) {
        var present = Set<String>()
        var fresh: [UsageEntry] = []
        var invalidated = false
        lastScanFullParses = 0
        lastScanTailParses = 0

        for path in paths {
            if walkedAll { present.insert(path) }
            let url = URL(fileURLWithPath: path)
            guard let (mtime, size) = Self.stat(url) else {
                // Named by an event but gone: deleted or renamed away. A file the walk just listed
                // that fails to stat is a transient error — keep its parse, as `present` does.
                if !walkedAll, !FileManager.default.fileExists(atPath: path),
                   cache.removeValue(forKey: path) != nil { invalidated = true }
                continue
            }
            if let hit = cache[path], hit.mtime == mtime, hit.size == size { continue }
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
            if let hit = cache.removeValue(forKey: path) {
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
                    if hit.tailCount > 0 {
                        entries.removeLast(min(hit.tailCount, entries.count))
                        invalidated = true      // those entries were already handed out
                    }
                    entries.append(contentsOf: tail.entries)
                    fresh.append(contentsOf: tail.entries)
                    cache[path] = CachedFile(
                        mtime: mtime, size: size, parsedUpTo: tail.parsedUpTo,
                        boundaryHash: Self.boundaryHash(of: url, endingAt: tail.parsedUpTo) ?? 0,
                        tailCount: tail.tailCount, entries: entries)
                    lastScanTailParses += 1
                    continue
                }
                // Fell through: put the old parse back so a failed read below can't lose it.
                cache[path] = hit
            }

            // Drain the parse temporaries per file so a big rescan doesn't balloon the peak.
            //
            // A read failure must NOT be cached. The key is (mtime, size), and a completed
            // subagent transcript is write-once — its key never changes again, so a cached `[]`
            // would zero that file for the life of the process, silently and unrecoverably.
            // `present` already holds this path (inserted above), so skipping here leaves any
            // prior good parse intact and un-evicted; the next scan retries the read.
            // (Explicit `invoking:` label — a trailing closure here would be parsed as the
            // guard's else-body.)
            guard let parsed = autoreleasepool(invoking: {
                try? JSONLParser.parse(fileAt: url, from: 0, projectDir: dir, interner: interner)
            }) else { continue }
            // A re-parse from zero replaces entries already handed out; a new file only adds.
            if cache[path] != nil { invalidated = true } else { fresh.append(contentsOf: parsed.entries) }
            cache[path] = CachedFile(
                mtime: mtime, size: size, parsedUpTo: parsed.parsedUpTo,
                boundaryHash: Self.boundaryHash(of: url, endingAt: parsed.parsedUpTo) ?? 0,
                tailCount: parsed.tailCount, entries: parsed.entries)
            lastScanFullParses += 1
        }
        // Forget files that disappeared.
        if walkedAll {
            for path in cache.keys where !present.contains(path) {
                cache[path] = nil
                invalidated = true
            }
        }
        return (fresh, invalidated)
    }

    /// Merge an `.appended` batch into the caller's sorted array, **in place**.
    ///
    /// The batch is usually entirely later than `entries.last`, so this is an append. When two
    /// sessions write at once it can reach back a few entries; only that suffix is re-sorted. The
    /// array must be uniquely referenced by the caller for this to be in place — `MetricsStore`
    /// owns `lastEntries` and the actor keeps no copy, which is what lets a delta avoid the full
    /// copy-on-write copy `AllocationTests` exists to catch.
    public static func mergeAppended(_ batch: [UsageEntry], repeats: [UsageEntry] = [],
                                     into entries: inout [UsageEntry]) {
        if let first = batch.first {
            let lo = upperBound(of: first.timestamp, in: entries)
            let needsSort = lo < entries.endIndex
            entries.append(contentsOf: batch)
            if needsSort { entries[lo...].sort { $0.timestamp < $1.timestamp } }
        }
        for r in repeats {
            guard let i = index(of: r.messageID, near: r.timestamp, in: entries) else {
                // The scanner only calls it a repeat if it delivered the key, so this means the
                // caller's array isn't the scanner's result. Keep the turn rather than lose it.
                entries.insert(r, at: upperBound(of: r.timestamp, in: entries))
                continue
            }
            let folded = entries[i].absorbing(r)
            if folded.timestamp == entries[i].timestamp {
                entries[i] = folded
            } else {
                // An earlier copy turned up late (another file). Rare; move the one entry.
                entries.remove(at: i)
                entries.insert(folded, at: upperBound(of: folded.timestamp, in: entries))
            }
        }
    }

    /// First index whose timestamp is later than `t`.
    private static func upperBound(of t: Date, in entries: [UsageEntry]) -> Int {
        var lo = entries.startIndex, hi = entries.endIndex
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].timestamp <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Where the held copy of `key` is. It began no later than this repeat in practice — a streaming
    /// snapshot seconds before, or the identical instant in a forked transcript — so search back from
    /// the repeat's own position first, and forward only for the rare earlier-copy-arrives-late case.
    private static func index(of key: MessageKey, near t: Date, in entries: [UsageEntry]) -> Int? {
        let start = upperBound(of: t, in: entries)
        var i = start
        while i > entries.startIndex {
            i -= 1
            if entries[i].messageID == key { return i }
        }
        return entries[start...].firstIndex { $0.messageID == key }
    }

    /// Map an FSEvents path onto the cache's key space, or nil if it isn't a transcript under the
    /// root. Mirrors `jsonlFiles`: `.jsonl` only, and nothing under a hidden component (the
    /// enumerator runs with `.skipsHiddenFiles`). FSEvents reports *resolved* paths, so a root
    /// reached through a symlink (`/var` → `/private/var`) is matched in both spellings — a miss
    /// here would make an existing file look new and count it twice.
    private func inRoot(_ path: String) -> String? {
        guard path.hasSuffix(".jsonl") else { return nil }
        let rootPath = Self.key(root)
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rel: Substring
        if path.hasPrefix(rootPath + "/") { rel = path.dropFirst(rootPath.count + 1) }
        else if path.hasPrefix(resolved + "/") { rel = path.dropFirst(resolved.count + 1) }
        else { return nil }
        if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return nil }
        return rootPath + "/" + rel
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

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
        var discarded = Set<MessageKey>()
        return merge(entries, deduplicated: deduplicated, keys: &discarded)
    }

    /// `keys` receives the dedup set (emptied in non-dedup mode), so the scanner can keep it as the
    /// base for later deltas instead of rebuilding it.
    static func merge(_ entries: consuming [UsageEntry], deduplicated: Bool,
                      keys seen: inout Set<MessageKey>) -> [UsageEntry] {
        var sorted = consume entries
        sorted.sort { $0.timestamp < $1.timestamp }
        seen.removeAll()
        guard deduplicated else { return sorted }
        // Compacted in place, not `filter` — two full copies of ~125k entries were a measurable part
        // of the scan's peak. Each key remembers where its entry landed so a later copy can be
        // folded into it (`absorbing`): the copies are streaming snapshots, and the last carries the
        // response's real usage. Sorted input means a fold never moves an entry.
        var slot = [MessageKey: Int](minimumCapacity: sorted.count)
        var w = sorted.startIndex
        for r in sorted.indices {
            let e = sorted[r]
            if let k = slot[e.messageID] {
                sorted[k] = sorted[k].absorbing(e)
            } else {
                slot[e.messageID] = w
                sorted[w] = e
                w += 1
            }
        }
        sorted.removeSubrange(w...)
        seen = Set(slot.keys)
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

    /// nil when the file doesn't exist (or can't be stat'd) — an FSEvents path can name a file that
    /// has since been deleted, which a directory walk never could.
    static func stat(_ url: URL) -> (Date, Int)? {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = v.contentModificationDate else { return nil }
        return (mtime, v.fileSize ?? 0)
    }
}
