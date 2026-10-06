import Foundation
import ClaudePetCore

/// The Mac's SoC temperature, thermal state, and this app's own CPU use — for the Today header.
///
/// **Still local only:** no network, no token, no file outside the ones the app already reads. The
/// temperature comes from IOKit's HID event system — the same sensors Activity-Monitor-class tools
/// read — through `IOHIDEventSystemClient`, which is **private API**. It is loaded with `dlsym`
/// rather than linked, so a macOS release that removes or renames a symbol degrades this to the
/// public `ProcessInfo.thermalState` alone instead of failing to launch.
///
/// A singleton read directly by `StatsHeaderView` rather than another `.environment` object: the
/// header is rendered from half a dozen roots (widget, dashboard, both snapshot paths) and every one
/// would need the injection, while there is only ever one machine to describe.
@MainActor @Observable
final class DeviceMonitor {
    static let shared = DeviceMonitor()

    private(set) var reading: DeviceReading?

    /// Slow on purpose. Temperature moves over tens of seconds, and the CPU figure is an average
    /// over the interval, so a longer one is a steadier number as well as a cheaper one.
    static let interval: TimeInterval = 15

    @ObservationIgnored private let sensors = SensorReader()
    /// The sensor read is an IPC round trip per service — measured ~34 ms for the M5's set, all of
    /// it blocked rather than computing, and on the main thread that is a dropped animation frame
    /// every 15 s. So it runs here and only the result hops back.
    @ObservationIgnored private let sensorQueue = DispatchQueue(label: "com.napat.ClaudePet.sensors",
                                                                qos: .utility)
    @ObservationIgnored private var previous: (cpu: Double, wall: Double)?
    @ObservationIgnored private var timer: Timer?

    private init() {
        if let raw = ProcessInfo.processInfo.environment["CLAUDEPET_DEVICE"],
           let fake = DeviceReading(fake: raw) {
            reading = fake
            return
        }
        // The first read is synchronous, once: the snapshot paths render immediately after this and
        // would otherwise always show the readout without its temperature.
        reading = DeviceReading(celsius: sensors.flatMap { ThermalSummary.socCelsius(from: $0.read()) },
                                pressure: Self.pressure(), cpuPercent: nil)
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in DeviceMonitor.shared.sample() }
        }
        t.tolerance = 5
        timer = t
    }

    private func sample() {
        let now = (cpu: Self.processCPUSeconds(), wall: ProcessInfo.processInfo.systemUptime)
        let cpu = previous.flatMap {
            CPUUsage.percent(prevCPU: $0.cpu, prevWall: $0.wall, cpu: now.cpu, wall: now.wall)
        }
        previous = now
        let pressure = Self.pressure()
        // Show the state and CPU at once; the temperature follows from the queue. Keeping the last
        // known temperature meanwhile avoids the readout blinking out and back every sample.
        reading = DeviceReading(celsius: reading?.celsius, pressure: pressure, cpuPercent: cpu)
        guard let sensors else { return }
        sensorQueue.async {
            let celsius = ThermalSummary.socCelsius(from: sensors.read())
            Task { @MainActor in DeviceMonitor.shared.reading?.celsius = celsius }
        }
    }

    private static func pressure() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    /// User + system CPU time of this process, all threads, in seconds.
    private static func processCPUSeconds() -> Double {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return 0 }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}

/// Thin `dlsym` wrapper over the private `IOHIDEventSystemClient` temperature API. `init?` fails
/// (and the header shows the thermal state alone) if any symbol is missing.
/// `@unchecked Sendable`: after `init` it is immutable, and `read()` is only ever called from
/// `DeviceMonitor.sensorQueue`, which is serial.
private final class SensorReader: @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    // From IOHIDFamily's headers: the vendor temperature page/usage, the temperature event type,
    // and its level field (`type << 16`).
    private static let usagePage = 0xff00, usage = 5
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    /// Held for the reader's lifetime: the service handles belong to it.
    private let client: AnyObject
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    /// Only the services that could be the SoC, named once at init — there are ~46 on an M5
    /// (battery, NAND, calibration…) and reading each costs an IPC round trip every sample.
    private let services: [(name: String, service: AnyObject)]

    init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let pCreate = dlsym(h, "IOHIDEventSystemClientCreate"),
              let pMatch = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let pServices = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let pProperty = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let pEvent = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let pFloat = dlsym(h, "IOHIDEventGetFloatValue") else { return nil }
        let create = unsafeBitCast(pCreate, to: CreateFn.self)
        let setMatching = unsafeBitCast(pMatch, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(pServices, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(pProperty, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(pEvent, to: CopyEventFn.self)
        getFloat = unsafeBitCast(pFloat, to: GetFloatFn.self)

        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        self.client = client
        _ = setMatching(client, ["PrimaryUsagePage": Self.usagePage, "PrimaryUsage": Self.usage] as CFDictionary)
        guard let all = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return nil }
        let candidates = ["tdie", "tdev", "cpu", "soc", "gpu", "mtr", "acc"]
        services = all.compactMap { s in
            guard let name = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  candidates.contains(where: { name.lowercased().contains($0) }) else { return nil }
            return (name, s)
        }
        guard !services.isEmpty else { return nil }
    }

    func read() -> [(name: String, celsius: Double)] {
        services.compactMap { s in
            guard let event = copyEvent(s.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue()
            else { return nil }
            return (s.name, getFloat(event, Self.temperatureField))
        }
    }
}
