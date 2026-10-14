import Foundation

/// How hot the Mac is, and how much of it this app is using — reduced from raw readings to the
/// two figures the widget prints. Pure, so the selection rules are unit-tested; the sensor and
/// `getrusage` reads live in the app target (`DeviceMonitor`).
public enum ThermalSummary {
    /// The SoC temperature to show, from `(sensor name, °C)` pairs, or nil if none is plausible.
    ///
    /// The **hottest die sensor**, because that is what throttles: on an M5 the 14 `PMU tdie*`
    /// sensors spanned 65–73 °C at one instant, and the mean hides the hot spot the OS reacts to.
    /// Tiers, first non-empty wins: `tdie` (die), then `tdev` (package/device), then anything named
    /// like a CPU/SoC/GPU sensor. Battery, NAND and calibration sensors (`tcal`) are never the
    /// chip. Readings outside 10–130 °C are dropped: the M5 reports `tdev1` at −22 °C, which is a
    /// reference channel, not a temperature anything is at.
    public static func socCelsius(from sensors: [(name: String, celsius: Double)]) -> Double? {
        let plausible = sensors.filter { (10...130).contains($0.celsius) }
        let tiers: [(String) -> Bool] = [
            { $0.asciiContains("tdie") },
            { $0.asciiContains("tdev") },
            { n in ["cpu", "soc", "gpu", "mtr", "acc"].contains { n.asciiContains($0) } },
        ]
        for matches in tiers {
            let hits = plausible.filter { matches($0.name) }.map(\.celsius)
            if let hottest = hits.max() { return hottest }
        }
        return nil
    }
}

/// `ProcessInfo.ThermalState`, mirrored so Core stays free of anything platform-flavoured and the
/// UI can colour by it. Public API, always available — the fallback when sensors can't be read.
public enum ThermalPressure: Int, Sendable, Comparable {
    case nominal, fair, serious, critical

    public var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum CPUUsage {
    /// This process's share of one core over an interval, from two samples of its CPU time
    /// (user + system) and wall clock, in seconds. 100 = one full core; can exceed 100 on several
    /// cores. Nil until there is a positive interval to divide by.
    public static func percent(prevCPU: Double, prevWall: Double, cpu: Double, wall: Double) -> Double? {
        let dWall = wall - prevWall
        guard dWall > 0 else { return nil }
        return max(0, (cpu - prevCPU) / dWall * 100)
    }
}

/// One reading for the header. `celsius` is nil when sensors are unavailable (the private API is
/// missing or returned nothing) — the state then stands alone.
public struct DeviceReading: Sendable, Equatable {
    public var celsius: Double?
    public var pressure: ThermalPressure
    public var cpuPercent: Double?

    public init(celsius: Double?, pressure: ThermalPressure, cpuPercent: Double?) {
        self.celsius = celsius
        self.pressure = pressure
        self.cpuPercent = cpuPercent
    }

    /// `CLAUDEPET_DEVICE="<celsius|none>,<nominal|fair|serious|critical>,<cpu>"` for snapshot
    /// renders — the same idea as `CLAUDEPET_UTIL`. Nil when the string doesn't parse.
    public init?(fake: String) {
        let parts = fake.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.count == 3 else { return nil }
        let states: [String: ThermalPressure] = ["nominal": .nominal, "fair": .fair,
                                                 "serious": .serious, "critical": .critical]
        guard let p = states[parts[1]] else { return nil }
        self.init(celsius: parts[0] == "none" ? nil : Double(parts[0]), pressure: p,
                  cpuPercent: Double(parts[2]))
    }
}

public extension Format {
    /// "73°C"
    static func celsius(_ c: Double) -> String { "\(Int(c.rounded()))°C" }

    /// "CPU 3%", or "CPU <1%" — an idle widget truly reads 0.3%, and "CPU 0%" looks like a broken
    /// reading rather than a quiet process.
    static func cpu(_ percent: Double) -> String {
        percent > 0 && percent < 1 ? "CPU <1%" : "CPU \(Int(percent.rounded()))%"
    }
}
