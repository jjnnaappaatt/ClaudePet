import Foundation

// MARK: - Days

/// A UTC calendar day as a plain integer: days since 1970-01-01.
///
/// **`/stats` cuts its days at UTC midnight, not local midnight.** Every date it stores goes through
/// `new Date(ts).toISOString().split("T")[0]`, which is the UTC date — so in UTC+7 a turn at 06:30
/// local belongs to *yesterday* in Claude Code's books. Matching it exactly means using the same
/// boundary, and an integer keeps any calendar out of it: the Buddhist calendar trap (year 2569)
/// cannot happen to arithmetic.
public enum StatsDay {
    public static func index(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// Days-from-civil (Hinnant). Exact for every Gregorian date; no `Calendar` involved.
    public static func index(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func index(of c: DateComponents) -> Int? {
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return index(year: y, month: m, day: d)
    }

    /// The inverse of `index(year:month:day:)`.
    public static func components(_ index: Int) -> DateComponents {
        let z = index + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return DateComponents(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
    }
}

// MARK: - Results

/// One transcript as `/stats` counts it: wall-clock span, entries, and when it began.
public struct StatsSession: Sendable, Equatable {
    public let duration: TimeInterval
    public let messageCount: Int
    public let start: Date

    public init(duration: TimeInterval, messageCount: Int, start: Date) {
        self.duration = duration
        self.messageCount = messageCount
        self.start = start
    }
}

/// What `/stats` adds on top of its cache: the days after `lastComputedDate`, through today.
public struct StatsDelta: Sendable, Equatable {
    /// The first UTC day this covers, i.e. the cache's last day + 1. A delta is only valid against
    /// the cache it was computed for: once Claude Code folds these days in, adding it again would
    /// count them twice.
    public var fromDay: Int?
    public var sessionCount = 0
    public var longestSession: StatsSession?
    public var earliestStart: Date?
    public var latestStart: Date?
    /// UTC day → messages, main transcripts only. A day is "active" exactly when it appears here.
    public var dailyMessages: [Int: Int] = [:]
    public var models: [String: StatsModelTotal] = [:]
    /// Local hour of each session's first entry → sessions.
    public var hourCounts: [Int: Int] = [:]
    public var totalMessages: Int { dailyMessages.values.reduce(0, +) }

    public init(fromDay: Int?) { self.fromDay = fromDay }
}

/// `/stats`' "All time" figures, as Claude Code would print them right now.
public struct StatsSnapshot: Sendable, Equatable {
    public let models: [StatsModelTotal]          // heaviest first
    public let totalSessions: Int
    public let totalMessages: Int
    public let activeDays: Int
    /// First session to latest activity, inclusive — the "167" in "146/167".
    public let totalDays: Int
    public let currentStreak: Int
    public let longestStreak: Int
    public let longestSession: StatsSession?
    public let firstSessionDate: Date?
    /// UTC y/m/d of the day with the most messages.
    public let mostActiveDay: DateComponents?
    public let peakHour: Int?
    /// True when a live delta is folded in; false when this is the cache alone.
    public let isLive: Bool
    /// Messages per UTC day (`StatsDay` index), cache and live delta merged — `/stats`' activity grid.
    public let dailyMessages: [Int: Int]

    /// `/stats`' shading for one day, 0…4: none, then by quartile of the active days' counts (`Od` in
    /// its bundle: ≥p75 → 4, ≥p50 → 3, ≥p25 → 2, else 1). The same four steps as its ░▒▓█ grid.
    public func activityLevel(_ day: Int) -> Int {
        guard let n = dailyMessages[day], n > 0 else { return 0 }
        let q = activityQuartiles
        if n >= q.p75 { return 4 }
        if n >= q.p50 { return 3 }
        if n >= q.p25 { return 2 }
        return 1
    }

    private var activityQuartiles: (p25: Int, p50: Int, p75: Int) {
        let v = dailyMessages.values.filter { $0 > 0 }.sorted()
        guard !v.isEmpty else { return (1, 1, 1) }
        func p(_ f: Double) -> Int { v[min(v.count - 1, Int(Double(v.count) * f))] }
        return (p(0.25), p(0.5), p(0.75))
    }

    /// `/stats`' "Total tokens" in the desktop app: input + output, cache excluded.
    public var totalWorkTokens: Int { models.reduce(0) { $0 + $1.workTokens } }

    /// The terminal `/stats`' "Total tokens": cache included, ~300× the figure above under prompt caching.
    public var totalTokensIncludingCache: Int { models.reduce(0) { $0 + $1.allTokens } }

    /// `/stats`' "Favourite model": the most tokens **including cache** (`ho` sorts by `Wo`). Not the
    /// first row of `models`, which ranks by input + output — the two disagree whenever the model
    /// you use now runs longer, cache-heavy sessions than the one that did most of the writing.
    public var favouriteModel: StatsModelTotal? {
        models.max { ($0.allTokens, $1.model) < ($1.allTokens, $0.model) }
    }

    /// Claude Code's own merge (`Yd` in its bundle), so every figure here is the one `/stats` shows.
    /// `delta` is ignored unless it was computed for this cache's watermark — see `StatsDelta.fromDay`.
    public static func merge(cache: StatsCache, delta: StatsDelta?, now: Date) -> StatsSnapshot {
        let delta = delta.flatMap { $0.fromDay == cache.nextDay ? $0 : nil }

        var daily = cache.dailyMessages
        var models = Dictionary(uniqueKeysWithValues: cache.models.map { ($0.model, $0) })
        var hours = cache.hourCounts
        var longest = cache.longestSession
        var first = cache.firstSessionDate
        if let d = delta {
            for (day, n) in d.dailyMessages { daily[day, default: 0] += n }
            for (id, m) in d.models {
                let b = models[id]
                models[id] = StatsModelTotal(
                    model: id,
                    inputTokens: (b?.inputTokens ?? 0) + m.inputTokens,
                    outputTokens: (b?.outputTokens ?? 0) + m.outputTokens,
                    cacheReadTokens: (b?.cacheReadTokens ?? 0) + m.cacheReadTokens,
                    cacheWriteTokens: (b?.cacheWriteTokens ?? 0) + m.cacheWriteTokens)
            }
            for (h, n) in d.hourCounts { hours[h, default: 0] += n }
            if let s = d.longestSession, s.duration > (longest?.duration ?? -1) { longest = s }
            if let e = d.earliestStart, first.map({ e < $0 }) ?? true { first = e }
        }

        let days = daily.keys.sorted()
        // Latest session start, else the last active day's UTC midnight — the same fallback.
        let lastDayStart: Date? = days.last.map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        let last: Date? = delta?.latestStart ?? lastDayStart
        var totalDays = 0
        if let f = first, let l = last {
            let span: Double = l.timeIntervalSince(f) / 86_400
            totalDays = Int(span.rounded(.up)) + 1
        }

        var current = 0
        let active = Set(days)
        var cursor = StatsDay.index(of: now)
        while active.contains(cursor) { current += 1; cursor -= 1 }

        var longestRun = 0, run = 0, prev: Int?
        for d in days {
            run = (prev.map { d - $0 == 1 } ?? false) ? run + 1 : 1
            longestRun = max(longestRun, run)
            prev = d
        }

        // Ties keep the earliest, as `reduce` with a strict `>` does in the original.
        let busiestDay = days.reduce(nil as Int?) { best, d in
            guard let b = best else { return d }
            return daily[d]! > daily[b]! ? d : b
        }
        let peakHour = hours.keys.sorted().reduce(nil as Int?) { best, h in
            guard hours[h]! > 0 else { return best }
            guard let b = best else { return h }
            return hours[h]! > hours[b]! ? h : b
        }

        return StatsSnapshot(
            models: models.values.filter { $0.workTokens > 0 || $0.cacheReadTokens > 0 }
                .sorted { ($0.workTokens, $0.model) > ($1.workTokens, $1.model) },
            totalSessions: cache.totalSessions + (delta?.sessionCount ?? 0),
            totalMessages: cache.totalMessages + (delta?.totalMessages ?? 0),
            activeDays: days.count,
            totalDays: totalDays,
            currentStreak: current,
            longestStreak: longestRun,
            longestSession: longest,
            firstSessionDate: first,
            mostActiveDay: busiestDay.map(StatsDay.components),
            peakHour: peakHour,
            isLive: delta != nil,
            dailyMessages: daily)
    }
}

// MARK: - Replica

/// Claude Code's `/stats`, recomputed from the same transcripts by the same rules — so the dashboard
/// shows what `/stats` would show *now*, not what it showed the last time someone opened it.
///
/// **Why this exists.** `~/.claude/stats-cache.json` is written only when the `/stats` dialog is
/// opened. Nothing else refreshes it, so between visits every figure in it freezes: it sat at
/// 17 September through 34 days of daily use, and the panel read 264.28M against `/stats`' real
/// 287.4M. Claude Code itself never shows that stale file — on open it folds every day after
/// `lastComputedDate` in from the transcripts, then adds today live. This does the same.
///
/// It is a port of `Fo` in Claude Code's bundle (v2.1.303), and every rule below is load-bearing —
/// each was needed to land on Claude Code's own numbers. Validated by refreshing the real cache from
/// a backed-up 17 Sep copy: **30 of 30 days matched exactly** on messages, sessions and per-model
/// tokens, and the whole span to the unit (479 sessions, 110,720 messages, 54,093,080 tokens).
///
/// - **Listing:** `projects/<dir>/*.jsonl` plus `projects/<dir>/<session>/subagents/agent-*.jsonl`,
///   one level only, regular files and real directories only (symlinks are skipped, as `Dirent`
///   type checks do). Workflow agents under `subagents/workflows/` are **not** counted.
/// - **A file larger than 100 MiB is read from its last 100 MiB only**, dropping the first partial
///   line. Without this the delta came out 12.7% high: the big live transcripts are exactly where
///   the most tokens are.
/// - **No dedup.** Every line counts, repeats included — the opposite of `Deduplicator`. This is
///   Claude Code's accounting, not ClaudePet's.
/// - In a main transcript, `isSidechain` lines are dropped entirely (tokens too); a subagent file
///   counts every line's tokens but contributes no messages, days or sessions.
/// - Only `user`/`assistant`/`attachment`/`system` lines count. Days are **UTC** (see `StatsDay`).
/// - A session is a main transcript whose first entry falls in range; one whose first or last entry
///   has a bad timestamp is skipped whole. Its hour is the *local* hour of that first entry.
/// - Files last modified before the range are not read at all; `<synthetic>` turns are ignored.
///
/// Incremental, like `UsageScanner`: a file at or under the limit is resumed from where it left off,
/// so an append costs only the new lines. One over the limit is re-read (its last 100 MiB) only when
/// its size or mtime changes, because the window slides as it grows.
///
/// Not `Sendable`: owned by `StatsReplicaScanner` (or used once, synchronously, by the snapshot path).
public final class StatsReplica {
    public static var defaultRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
    }
    /// `F` in the original.
    public static let tailLimit: UInt64 = 104_857_600

    public let root: String
    let tailLimit: UInt64

    public init(root: String = StatsReplica.defaultRoot, tailLimit: UInt64 = StatsReplica.tailLimit) {
        self.root = root
        self.tailLimit = tailLimit
    }

    struct Tokens { var input = 0, output = 0, cacheRead = 0, cacheWrite = 0 }

    struct DayTally {
        var messages = 0
        var models: [String: Tokens] = [:]
    }

    /// One file's contribution, kept per UTC day so a later cache watermark can re-slice it without
    /// a re-read.
    struct FileTally {
        var size: UInt64 = 0
        var mtime = Date.distantPast
        var parsedUpTo: UInt64 = 0
        /// Built from the last-`tailLimit` window, so it can't be resumed — only rebuilt.
        var isWindow = false
        var count = 0                 // entries surviving the type/sidechain filter (`ke.length`)
        var firstSeen = false
        var firstTime: Date?          // nil after `firstSeen` = an unparseable timestamp
        var lastTime: Date?
        var days: [Int: DayTally] = [:]
    }

    private var tallies: [String: FileTally] = [:]
    private let interner = StringInterner()

    struct Listed {
        let path: String
        let isSubagent: Bool
        let size: UInt64
        let mtime: Date
    }

    /// Everything `/stats` would add on top of a cache whose last day is `fromDay - 1`, through
    /// today (UTC). `fromDay == nil` means no cache at all, i.e. all history.
    public func delta(fromDay: Int?, now: Date = Date(), timeZone: TimeZone = .current) -> StatsDelta {
        let files = list()
        let live = Set(files.map(\.path))
        tallies = tallies.filter { live.contains($0.key) }
        let toDay = StatsDay.index(of: now)
        var hourCal = Calendar(identifier: .gregorian)
        hourCal.timeZone = timeZone

        var out = StatsDelta(fromDay: fromDay)
        for f in files {
            if let from = fromDay, StatsDay.index(of: f.mtime) < from { continue }
            let t = refresh(f)
            accumulate(t, isSubagent: f.isSubagent, from: fromDay, to: toDay, hourCal: hourCal, into: &out)
        }
        return out
    }

    private func accumulate(_ t: FileTally, isSubagent: Bool, from: Int?, to: Int,
                            hourCal: Calendar, into out: inout StatsDelta) {
        guard t.count > 0, let start = t.firstTime, let end = t.lastTime else { return }
        let startDay = StatsDay.index(of: start)
        if startDay > to { return }
        if !isSubagent, from.map({ startDay >= $0 }) ?? true {
            let s = StatsSession(duration: end.timeIntervalSince(start), messageCount: t.count, start: start)
            out.sessionCount += 1
            if s.duration > (out.longestSession?.duration ?? -1) { out.longestSession = s }
            if out.earliestStart.map({ start < $0 }) ?? true { out.earliestStart = start }
            if out.latestStart.map({ start > $0 }) ?? true { out.latestStart = start }
            out.hourCounts[hourCal.component(.hour, from: start), default: 0] += 1
        }
        for (day, d) in t.days where day <= to && from.map({ day >= $0 }) ?? true {
            if !isSubagent, d.messages > 0 { out.dailyMessages[day, default: 0] += d.messages }
            for (id, k) in d.models {
                let b = out.models[id]
                out.models[id] = StatsModelTotal(
                    model: id,
                    inputTokens: (b?.inputTokens ?? 0) + k.input,
                    outputTokens: (b?.outputTokens ?? 0) + k.output,
                    cacheReadTokens: (b?.cacheReadTokens ?? 0) + k.cacheRead,
                    cacheWriteTokens: (b?.cacheWriteTokens ?? 0) + k.cacheWrite)
            }
        }
    }

    // MARK: Files

    /// `mr` in the original. `lstat`, never `stat`: the original's `Dirent.isFile()` / `isDirectory()`
    /// are false for a symlink, so a linked transcript or project folder is not counted. (Claude Code
    /// symlinks workflow agent folders between sessions — following them would count a file twice.)
    func list() -> [Listed] {
        enum Kind { case file, dir, other }
        func kind(_ path: String) -> (Kind, UInt64, Date)? {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                             + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
            switch st.st_mode & S_IFMT {
            case S_IFREG: return (.file, UInt64(st.st_size), mtime)
            case S_IFDIR: return (.dir, 0, mtime)
            default: return (.other, 0, mtime)
            }
        }
        func names(_ dir: String) -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        }

        var out: [Listed] = []
        for project in names(root) {
            let pdir = root + "/" + project
            guard kind(pdir)?.0 == .dir else { continue }
            for name in names(pdir) {
                let path = pdir + "/" + name
                guard let (k, size, mtime) = kind(path) else { continue }
                if name.hasSuffix(".jsonl") {
                    if k == .file { out.append(Listed(path: path, isSubagent: false, size: size, mtime: mtime)) }
                } else if k == .dir {
                    let sdir = path + "/subagents"
                    for agent in names(sdir) where agent.hasPrefix("agent-") && agent.hasSuffix(".jsonl") {
                        let apath = sdir + "/" + agent
                        if let (ak, asize, amtime) = kind(apath), ak == .file {
                            out.append(Listed(path: apath, isSubagent: true, size: asize, mtime: amtime))
                        }
                    }
                }
            }
        }
        return out
    }

    private func refresh(_ f: Listed) -> FileTally {
        var t = tallies[f.path] ?? FileTally()
        defer { tallies[f.path] = t }
        if t.size == f.size, t.mtime == f.mtime, t.parsedUpTo > 0 || t.isWindow { return t }

        if f.size > tailLimit {
            t = FileTally()
            t.isWindow = true
            read(f, from: f.size - tailLimit, skipFirstLine: true, into: &t)
        } else {
            // Shorter than what we consumed, or previously windowed: not the same bytes any more.
            if f.size < t.parsedUpTo || t.isWindow { t = FileTally() }
            read(f, from: t.parsedUpTo, skipFirstLine: false, into: &t)
        }
        t.size = f.size
        t.mtime = f.mtime
        return t
    }

    /// Reads complete lines from `offset`. A half-written final line is left for next time — it is
    /// counted once it has its newline, and every transcript sampled ends with one.
    private func read(_ f: Listed, from offset: UInt64, skipFirstLine: Bool, into t: inout FileTally) {
        guard let handle = FileHandle(forReadingAtPath: f.path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return }
        var buffer = Data()
        var skipping = skipFirstLine
        var consumed = offset
        // The read itself must sit inside the pool. `readData` hands back an autoreleased buffer, so
        // reading in the `while` condition parked every 1 MB chunk in the caller's pool until the
        // whole pass ended: 2,223 of them live at once, a 3.8 GB peak for a 2.4 GB fold-in.
        var more = true
        while more {
            autoreleasepool {
                let chunk = handle.readData(ofLength: 1 << 20)
                guard !chunk.isEmpty else { more = false; return }
                buffer.append(chunk)
                let used = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    var lineStart = 0
                    while lineStart < raw.count,
                          let hit = memchr(base + lineStart, 0x0A, raw.count - lineStart) {
                        let end = UnsafeRawPointer(hit) - base
                        if skipping { skipping = false } else if end > lineStart {
                            ingest(UnsafeRawBufferPointer(rebasing: raw[lineStart..<end]),
                                   isSubagent: f.isSubagent, into: &t)
                        }
                        lineStart = end + 1
                    }
                    return lineStart
                }
                consumed += UInt64(used)
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + used))
            }
        }
        if !t.isWindow { t.parsedUpTo = consumed }
    }

    // MARK: Lines

    private static let typeProbes: [[UInt8]] = ["user", "assistant", "attachment", "system"]
        .map { Array("\"type\":\"\($0)\"".utf8) }
    private static let countedTypes: Set<String> = ["user", "assistant", "attachment", "system"]
    /// `model in Object.prototype` in the original — ids it refuses to use as a key.
    private static let prototypeKeys: Set<String> = [
        "constructor", "__proto__", "toString", "toLocaleString", "valueOf", "hasOwnProperty",
        "isPrototypeOf", "propertyIsEnumerable", "__defineGetter__", "__defineSetter__",
        "__lookupGetter__", "__lookupSetter__",
    ]
    private static let decoder = JSONDecoder()

    /// Only the fields `/stats` reads, each decoded leniently: a field of the wrong shape is
    /// `undefined` to the original, never a reason to drop the line.
    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let isSidechain: Bool
        let model: String?
        let usage: Usage?

        struct Usage: Decodable {
            let input, output, cacheRead, cacheWrite: Int
            enum K: String, CodingKey {
                case input = "input_tokens", output = "output_tokens"
                case cacheRead = "cache_read_input_tokens", cacheWrite = "cache_creation_input_tokens"
            }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                func n(_ k: K) -> Int { (try? c.decode(Int.self, forKey: k)) ?? 0 }
                input = n(.input); output = n(.output); cacheRead = n(.cacheRead); cacheWrite = n(.cacheWrite)
            }
        }
        struct Message: Decodable { let model: String?; let usage: Usage?
            enum K: String, CodingKey { case model, usage }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                model = try? c.decode(String.self, forKey: .model)
                usage = try? c.decode(Usage.self, forKey: .usage)
            }
        }
        enum K: String, CodingKey { case type, timestamp, isSidechain, message }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            type = try? c.decode(String.self, forKey: .type)
            timestamp = try? c.decode(String.self, forKey: .timestamp)
            isSidechain = (try? c.decode(Bool.self, forKey: .isSidechain)) ?? false
            let m = try? c.decode(Message.self, forKey: .message)
            model = m?.model
            usage = m?.usage
        }
    }

    private func ingest(_ bytes: UnsafeRawBufferPointer, isSubagent: Bool, into t: inout FileTally) {
        // One-directional, like `JSONLParser`'s `"usage"` probe: Claude Code writes compact JSON, so
        // a counted line always spells one of these; a false positive just costs the decode.
        guard Self.typeProbes.contains(where: { bytes.contains($0) }) else { return }
        // No copy: the bytes outlive the decode, and a per-line `Data(bytes)` duplicated every
        // transcript line — up to 100 MiB per changed big file — only to throw it away.
        let view = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
                        count: bytes.count, deallocator: .none)
        guard let line = try? Self.decoder.decode(Line.self, from: view),
              let type = line.type, Self.countedTypes.contains(type) else { return }
        if !isSubagent && line.isSidechain { return }

        t.count += 1
        let time = line.timestamp.flatMap(TimestampParser.date(from:))
        if !t.firstSeen { t.firstSeen = true; t.firstTime = time }
        t.lastTime = time
        guard let time else { return }

        let day = StatsDay.index(of: time)
        if !isSubagent { t.days[day, default: DayTally()].messages += 1 }
        guard type == "assistant", let u = line.usage else { return }
        let model = line.model.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        guard model != "<synthetic>", !Self.prototypeKeys.contains(model) else { return }
        var k = t.days[day, default: DayTally()].models[model] ?? Tokens()
        k.input += u.input; k.output += u.output; k.cacheRead += u.cacheRead; k.cacheWrite += u.cacheWrite
        t.days[day, default: DayTally()].models[interner.intern(model)] = k
    }
}

private extension UnsafeRawBufferPointer {
    func contains(_ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard let base = baseAddress, count >= n else { return false }
        return needle.withUnsafeBufferPointer { nb -> Bool in
            var searched = 0
            while searched <= count - n {
                guard let hit = memchr(base + searched, Int32(nb[0]), count - n - searched + 1) else { return false }
                if memcmp(hit, nb.baseAddress!, n) == 0 { return true }
                searched = (UnsafeRawPointer(hit) - base) + 1
            }
            return false
        }
    }
}

/// The live owner of a `StatsReplica`, so its per-file cache survives between refreshes and the
/// reading happens off the main actor — a stale cache can mean gigabytes of transcripts to fold in.
public actor StatsReplicaScanner {
    private let replica: StatsReplica

    public init(root: String) { replica = StatsReplica(root: root) }

    public func delta(fromDay: Int?, now: Date, timeZone: TimeZone) -> StatsDelta {
        replica.delta(fromDay: fromDay, now: now, timeZone: timeZone)
    }
}
