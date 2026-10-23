import Foundation

/// Codex's quota, read straight from its own session rollouts in `~/.codex/sessions`.
///
/// **Why this exists alongside `CodexUsageReader`:** that one reads `/tmp/claude/codex-usage-cache.tsv`,
/// which only the terminal statusline writes — and `/tmp` is emptied on every restart. After a reboot
/// the Codex row stayed blank until a terminal `claude` session happened to render a statusline (the
/// desktop app's Code tab never does), even though every number it needed was sitting in the
/// rollouts the whole time. This reads those directly: same files, same algorithm, no dependency on
/// a terminal being open. Local only — no token, no network, same as everything else here.
///
/// It is a port of two pieces of the statusline, and must agree with them:
/// - **The percentage** (`codex_usage` in `~/.claude/statusline.sh`): the newest rollouts by mtime
///   (at most 5), the last line of each one's final 200 KB that carries `"rate_limits"`, its
///   `primary` and `secondary` windows, stamped with that record's own `timestamp`.
/// - **The token count** (`~/.claude/codex-week-tokens.py`): positive deltas of
///   `input_tokens - cached_input_tokens + output_tokens` over `total_token_usage` records stamped
///   inside the window, from rollouts modified at or after the window start. Codex's `input_tokens`
///   is gross (cache included), so the subtraction is what makes this a "work" figure — the script's
///   docstring has the measurements behind each choice; they are not repeated here.
///
/// Not an actor and not `Sendable`: `MetricsStore` owns one and calls it from the main actor only.
public final class CodexRolloutReader {
    public static let defaultRoot = NSHomeDirectory() + "/.codex/sessions"

    public let root: String

    public init(root: String = CodexRolloutReader.defaultRoot) {
        self.root = root
    }

    /// One token record: when it was written and the cache-excluded cumulative at that point.
    struct TokenRecord: Equatable {
        let epoch: Int
        let cumulative: Int
    }

    /// Per-file token records, resumed from `parsedUpTo` when the file grows.
    ///
    /// Rollouts are append-only and the live one reaches tens of MB, while recompute runs on the
    /// main actor every time a Claude transcript or a rollout changes — so a whole-file re-read on
    /// every Codex write would be `UsageScanner`'s old CPU problem again. Only complete lines are
    /// consumed; a half-written final line is read next time, once it has its newline.
    struct TokenFile {
        var parsedUpTo: UInt64
        var records: [TokenRecord]
    }
    private var tokenFiles: [String: TokenFile] = [:]

    /// The newest rollout's snapshot, keyed by its stat so an unchanged file isn't re-read.
    private var snapshotCache: (path: String, mtime: Date, size: UInt64, rows: [SnapshotRow])?

    struct SnapshotRow: Equatable {
        let windowMinutes: Int
        let usedPercent: Double
        let resetsAt: Int
        let recordedAt: Int
    }

    struct RolloutFile {
        let path: String
        let mtime: Date
        let size: UInt64
    }

    /// Every Codex window the newest rollouts report, short window first. `[]` when there is no
    /// Codex, or no rollout carries a rate-limit snapshot yet.
    public func read() -> [CodexLimit] {
        let files = rolloutFiles()
        guard let rows = latestSnapshot(in: files), !rows.isEmpty else { return [] }
        refreshTokenRecords(for: files, since: rows.map { windowStart($0) }.min() ?? 0)
        return rows.map { row in
            let tokens = tokensUsed(since: windowStart(row), in: files)
            return CodexLimit(windowMinutes: row.windowMinutes,
                              utilization: row.usedPercent,
                              resetsAt: Date(timeIntervalSince1970: TimeInterval(row.resetsAt)),
                              recordedAt: Date(timeIntervalSince1970: TimeInterval(row.recordedAt)),
                              tokensUsed: tokens > 0 ? tokens : nil)
        }
        .sorted { $0.windowMinutes < $1.windowMinutes }
    }

    /// The newest rollout mtime, for `MetricsStore`'s "has anything changed?" test. A directory walk
    /// of `YYYY/MM/DD` folders — a few `readdir`s, not a read of any file.
    public func latestModification() -> Date? {
        rolloutFiles().map(\.mtime).max()
    }

    /// The token count alone, for an arbitrary window start — what `codex-week-tokens.py <start>`
    /// prints. Lets the two be compared over any span, not just the live windows.
    func tokensUsed(since windowStart: Int) -> Int {
        let files = rolloutFiles()
        refreshTokenRecords(for: files, since: windowStart)
        return tokensUsed(since: windowStart, in: files)
    }

    private func windowStart(_ row: SnapshotRow) -> Int {
        row.resetsAt - row.windowMinutes * 60
    }

    // MARK: - Files

    /// `root/*/*/*/rollout-*.jsonl` — the script's glob. Codex files sessions by date.
    func rolloutFiles() -> [RolloutFile] {
        let fm = FileManager.default
        func children(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }
        }
        var out: [RolloutFile] = []
        for year in children(root) {
            for month in children(year) {
                for day in children(month) {
                    for path in children(day) {
                        let name = (path as NSString).lastPathComponent
                        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                              let attrs = try? fm.attributesOfItem(atPath: path),
                              attrs[.type] as? FileAttributeType == .typeRegular,
                              let mtime = attrs[.modificationDate] as? Date,
                              let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
                        out.append(RolloutFile(path: path, mtime: mtime, size: size))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Percentage

    private static let tailBytes: UInt64 = 200_000
    private static let rateLimitsKey = Array(#""rate_limits""#.utf8)
    private static let totalUsageKey = Array(#""total_token_usage""#.utf8)

    /// A rollout that has only just started can carry no snapshot yet, so walk back through the
    /// newest five until one does — the statusline's rule.
    private func latestSnapshot(in files: [RolloutFile]) -> [SnapshotRow]? {
        for file in files.sorted(by: { $0.mtime > $1.mtime }).prefix(5) {
            if let c = snapshotCache, c.path == file.path, c.mtime == file.mtime, c.size == file.size {
                return c.rows
            }
            if let rows = Self.snapshot(inTailOf: file) {
                snapshotCache = (file.path, file.mtime, file.size, rows)
                return rows
            }
        }
        return nil
    }

    static func snapshot(inTailOf file: RolloutFile) -> [SnapshotRow]? {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }
        let start = file.size > tailBytes ? file.size - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // Newest line first. The tail can open mid-line; that fragment simply fails to parse.
        for line in lines(in: data).reversed() where contains(line, rateLimitsKey) {
            if let rows = snapshotRows(fromLine: line) { return rows }
        }
        return nil
    }

    /// One line's `rate_limits` as rows, or nil when the line has none usable. A window with a
    /// missing field is dropped, never defaulted — same rule as `CodexUsageReader`.
    static func snapshotRows(fromLine line: Data) -> [SnapshotRow]? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let limits = findRateLimits(in: obj) else { return nil }
        let stamp = (obj["timestamp"] as? String) ?? (obj["ts"] as? String) ?? ""
        let recorded = epochSeconds(stamp) ?? 0
        let rows = ["primary", "secondary"].compactMap { key -> SnapshotRow? in
            guard let w = limits[key] as? [String: Any],
                  let minutes = (w["window_minutes"] as? NSNumber)?.intValue,
                  let pct = (w["used_percent"] as? NSNumber)?.doubleValue,
                  let reset = (w["resets_at"] as? NSNumber)?.intValue,
                  minutes > 0, pct >= 0 else { return nil }
            return SnapshotRow(windowMinutes: minutes, usedPercent: pct, resetsAt: reset,
                               recordedAt: recorded)
        }
        return rows.isEmpty ? nil : rows
    }

    /// The first `rate_limits` object anywhere in the record (jq's `..`): it sits under `payload`
    /// today, and the statusline deliberately doesn't pin the path.
    private static func findRateLimits(in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let r = dict["rate_limits"] as? [String: Any] { return r }
            for v in dict.values { if let r = findRateLimits(in: v) { return r } }
        } else if let array = value as? [Any] {
            for v in array { if let r = findRateLimits(in: v) { return r } }
        }
        return nil
    }

    /// Whole seconds, fraction dropped — what both the statusline (`sub("\\.[0-9]+Z$"; "Z")`) and the
    /// script (`rest[:8]`) do, so a record a few ms into the window's first second compares the same.
    static func epochSeconds(_ stamp: String) -> Int? {
        TimestampParser.date(from: stamp).map { Int($0.timeIntervalSince1970.rounded(.down)) }
    }

    // MARK: - Token count

    /// Bring every rollout that could hold a record inside the oldest window up to date, and forget
    /// files that have gone (Codex archives old sessions out of this folder).
    private func refreshTokenRecords(for files: [RolloutFile], since windowStart: Int) {
        let live = Set(files.map(\.path))
        tokenFiles = tokenFiles.filter { live.contains($0.key) }
        for file in files where file.mtime.timeIntervalSince1970 >= TimeInterval(windowStart) {
            var entry = tokenFiles[file.path] ?? TokenFile(parsedUpTo: 0, records: [])
            // A shorter file is not this file any more. Rollouts are append-only, so this is the
            // replaced/truncated case only — start over rather than resume into the middle of a line.
            if file.size < entry.parsedUpTo { entry = TokenFile(parsedUpTo: 0, records: []) }
            if file.size > entry.parsedUpTo {
                Self.appendRecords(from: file.path, into: &entry)
            }
            tokenFiles[file.path] = entry
        }
    }

    static func appendRecords(from path: String, into entry: inout TokenFile) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: entry.parsedUpTo)) != nil else { return }
        var buffer = Data()
        // Read inside the pool — in the `while` condition every chunk was parked in the caller's pool
        // until the file ended (see `JSONLParser.parse`).
        var more = true
        while more {
            autoreleasepool {
                let chunk = handle.readData(ofLength: 1 << 20)
                guard !chunk.isEmpty else { more = false; return }
                buffer.append(chunk)
                guard let last = lastNewline(in: buffer) else { return }
                let complete = buffer[buffer.startIndex..<(buffer.startIndex + last)]
                for line in lines(in: complete) where contains(line, totalUsageKey) {
                    if let r = tokenRecord(fromLine: line) { entry.records.append(r) }
                }
                entry.parsedUpTo += UInt64(last + 1)
                buffer.removeSubrange(buffer.startIndex...(buffer.startIndex + last))
            }
        }
    }

    static func tokenRecord(fromLine line: Data) -> TokenRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let input = (usage["input_tokens"] as? NSNumber)?.intValue,
              let output = (usage["output_tokens"] as? NSNumber)?.intValue else { return nil }
        // Absent on an older Codex, where input was already net of cache.
        let cached = (usage["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
        // 0 for an unparseable stamp, as in the script: the record is kept as the next delta's
        // baseline but never credited to a window.
        let epoch = epochSeconds((obj["timestamp"] as? String) ?? "") ?? 0
        return TokenRecord(epoch: epoch, cumulative: input - cached + output)
    }

    /// Σ positive deltas over records stamped inside the window. The baseline is the previous
    /// record even when that one predates the window — the delta belongs to the turn that closed it.
    /// A dip is clamped to 0 and the baseline follows it down, so the recovery is credited next time.
    private func tokensUsed(since windowStart: Int, in files: [RolloutFile]) -> Int {
        var total = 0
        for file in files where file.mtime.timeIntervalSince1970 >= TimeInterval(windowStart) {
            var prev = 0
            for r in tokenFiles[file.path]?.records ?? [] {
                if r.epoch >= windowStart { total += max(0, r.cumulative - prev) }
                prev = r.cumulative
            }
        }
        return total
    }

    // MARK: - Bytes

    /// Lines as slices of `data`, split with `memchr` — `Data`'s generic `firstIndex(of:)`/`split`
    /// is the cost `JSONLParser.lineOffsets` measured at 28% of a scan.
    private static func lines(in data: Data) -> [Data] {
        var out: [Data] = []
        var start = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while start < raw.count, let hit = memchr(base + start, 0x0A, raw.count - start) {
                let nl = UnsafeRawPointer(hit) - base
                if nl > start { out.append(data[(data.startIndex + start)..<(data.startIndex + nl)]) }
                start = nl + 1
            }
        }
        if start < data.count { out.append(data[(data.startIndex + start)..<data.endIndex]) }
        return out
    }

    private static func lastNewline(in data: Data) -> Int? {
        // No `memrchr` on Darwin. Walked backwards over raw bytes, so it stops at the first newline
        // from the end rather than scanning the whole megabyte.
        data.withUnsafeBytes { raw -> Int? in
            var i = raw.count - 1
            while i >= 0 { if raw[i] == 0x0A { return i }; i -= 1 }
            return nil
        }
    }

    private static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let n = needle.count
            guard let base = raw.baseAddress, raw.count >= n else { return false }
            return needle.withUnsafeBufferPointer { nb -> Bool in
                var searched = 0
                while searched <= raw.count - n {
                    guard let hit = memchr(base + searched, Int32(nb[0]),
                                           raw.count - n - searched + 1) else { return false }
                    if memcmp(hit, nb.baseAddress!, n) == 0 { return true }
                    searched = (UnsafeRawPointer(hit) - base) + 1
                }
                return false
            }
        }
    }
}
