import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct DeviceThermalsTests {

    /// A trimmed copy of what an M5 MacBook actually reported, including the traps: a −22 °C
    /// reference channel, a calibration sensor, battery and NAND sensors hotter or colder than the die.
    private let m5: [(name: String, celsius: Double)] = [
        ("NAND CH0 temp", 53.0), ("PMU tcal", 51.8), ("PMU tdev1", -21.7), ("PMU tdev2", 58.3),
        ("PMU tdie1", 73.0), ("PMU tdie2", 65.5), ("PMU tdie8", 73.1), ("PMU2 tdie1", 56.4),
        ("gas gauge battery", 30.3),
    ]

    @Test func picksTheHottestDieSensor() {
        #expect(ThermalSummary.socCelsius(from: m5) == 73.1)
    }

    @Test func fallsBackThroughTiersAndIgnoresImplausibleReadings() {
        let noDie = m5.filter { !$0.name.contains("tdie") }
        #expect(ThermalSummary.socCelsius(from: noDie) == 58.3)          // tdev, and not −21.7
        let older = [("pACC MTR Temp Sensor0", 48.0), ("GPU MTR Temp Sensor1", 51.5),
                     ("gas gauge battery", 31.0)]
        #expect(ThermalSummary.socCelsius(from: older.map { (name: $0.0, celsius: $0.1) }) == 51.5)
        let nothing = [("gas gauge battery", 31.0), ("NAND CH0 temp", 40.0), ("PMU tdie1", 400.0)]
        #expect(ThermalSummary.socCelsius(from: nothing.map { (name: $0.0, celsius: $0.1) }) == nil)
    }

    @Test func cpuPercentIsShareOfOneCore() {
        // 0.3 s of CPU over 15 s of wall clock is 2% of a core.
        #expect(abs(CPUUsage.percent(prevCPU: 10, prevWall: 100, cpu: 10.3, wall: 115)! - 2) < 1e-9)
        #expect(CPUUsage.percent(prevCPU: 0, prevWall: 5, cpu: 1, wall: 5) == nil)
        #expect(CPUUsage.percent(prevCPU: 5, prevWall: 0, cpu: 4, wall: 1) == 0)   // never negative
    }

    @Test func formatting() {
        #expect(Format.celsius(72.6) == "73°C")
        #expect(Format.cpu(0.3) == "CPU <1%")
        #expect(Format.cpu(0) == "CPU 0%")
        #expect(Format.cpu(6.6) == "CPU 7%")
        #expect(Format.tokensPrecise(123_141_592) == "123.14M")
        #expect(Format.tokensPrecise(12_400) == "12.4k")
        // Grouping separator follows the user's locale, so check the digits rather than the comma.
        #expect(Format.currencyWhole(21_138.4).filter(\.isNumber) == "21138")
        #expect(Format.currencyWhole(42.5) == "$42.50")
    }

    @Test func fakeReadingParses() {
        #expect(DeviceReading(fake: "54,serious,3") == DeviceReading(celsius: 54, pressure: .serious, cpuPercent: 3))
        #expect(DeviceReading(fake: "none,fair,0.4")?.celsius == nil)
        #expect(DeviceReading(fake: "54,hot,3") == nil)
    }
}
