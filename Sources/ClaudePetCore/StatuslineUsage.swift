import Foundation

/// One server-reported limit window (5-hour or 7-day) as read from the claude-statusline
/// local cache. The `utilization` is Claude's real percentage; `resetsAt` is the real reset.
public struct ServerLimit: Sendable, Equatable {
    public let utilization: Double       // 0–100 %, server-reported
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// Usable only while its window hasn't reset yet — once `now >= resetsAt` the cached
    /// percentage describes a window that has already rolled over, so it's no longer valid.
    public func isUsable(now: Date = Date()) -> Bool {
        guard let r = resetsAt else { return false }
        return now < r
    }

    public var fraction: Double { min(1, max(0, utilization / 100)) }
}

/// Claude's real 5h / 7-day usage, read from the claude-statusline cache file.
///
/// IMPORTANT: ClaudePet never fetches this itself — no OAuth token, no Keychain, no network.
/// It only reads the local JSON file the user's installed statusline already wrote (same
/// class of action as reading `~/.claude.json`). The token is never present in this file.
public struct StatuslineUsage: Sendable, Equatable {
    public let fiveHour: ServerLimit?
    public let sevenDay: ServerLimit?
    public let asOf: Date                // cache-file modification time (freshness, for the UI)

    public init(fiveHour: ServerLimit?, sevenDay: ServerLimit?, asOf: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.asOf = asOf
    }
}

public enum StatuslineUsageReader {
    public static let defaultPath = "/tmp/claude/statusline-usage-cache.json"

    // The cache carries many extra fields (seven_day_opus, extra_usage, …); we decode only
    // the two we use. Codable ignores the rest.
    private struct Raw: Decodable {
        struct Limit: Decodable { let utilization: Double?; let resets_at: String? }
        let five_hour: Limit?
        let seven_day: Limit?
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private static func limit(_ l: Raw.Limit?) -> ServerLimit? {
        guard let l, let u = l.utilization else { return nil }
        return ServerLimit(utilization: u, resetsAt: parseDate(l.resets_at))
    }

    /// Reads and parses the statusline cache. Returns nil if the file is absent, unreadable,
    /// malformed, or carries neither limit — callers then fall back to the local estimate.
    public static func read(path: String = defaultPath) -> StatuslineUsage? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let five = limit(raw.five_hour)
        let seven = limit(raw.seven_day)
        guard five != nil || seven != nil else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return StatuslineUsage(fiveHour: five, sevenDay: seven, asOf: mtime ?? Date())
    }
}
