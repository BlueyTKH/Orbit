import Foundation
import IOKit

/// Read-only macOS telemetry. Adapter rating is never presented as actual input.
struct BatteryMenuSnapshot: Equatable, Sendable {
    var level: Int? = nil
    var pluggedIn = false
    var charging = false
    var full = false
    var lowPower = false
    var inputWatts: Double?
    var batteryWatts: Double?
    var adapterRating: Int?
    var volts: Double?
    var amps: Double?
    var cycles: Int?
    var capacity: Int?
    var designCapacity: Int?
    var health: Int?
    var condition: String?
    var eta: String?
    var devices: [BatteryMenuDevice] = []
    var appEnergy: [BatteryMenuAppEnergy] = []
    var history: [BatteryMenuPoint] = []

    var systemWatts: Double? {
        if pluggedIn {
            guard let inputWatts, let batteryWatts, inputWatts - batteryWatts >= -0.5 else { return nil }
            return max(0, inputWatts - batteryWatts)
        }
        return batteryWatts.flatMap { $0 <= 0 ? -$0 : nil }
    }
    var state: String {
        if !pluggedIn { return lowPower ? "On battery (Low Power Mode)" : "On battery" }
        if let batteryWatts, batteryWatts < -0.5 { return "Battery helping the charger" }
        if charging { return "Charging" }
        return (full ? "Fully charged" : "Charging paused") + (lowPower ? " (Low Power Mode)" : "")
    }
    var batteryFlow: String {
        guard let batteryWatts else { return "Battery flow unavailable" }
        if abs(batteryWatts) < 0.5 { return "Battery resting" }
        return batteryWatts > 0 ? "Into the battery" : "From the battery"
    }
    static func watts(_ value: Double?) -> String {
        value.map { String(format: "%.1f W", abs($0)) } ?? "—"
    }
    static func validWatts(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && abs($0) <= 500 ? $0 : nil }
    }
    static func parse(_ data: [String: Any], lowPower: Bool) -> Self {
        func number(_ key: String) -> Double? { (data[key] as? NSNumber)?.doubleValue }
        var s = Self()
        s.lowPower = lowPower
        s.pluggedIn = data["ExternalConnected"] as? Bool ?? false
        s.charging = data["IsCharging"] as? Bool ?? false
        s.full = data["FullyCharged"] as? Bool ?? false
        if let percent = number("CurrentCapacity"), (0...100).contains(percent) { s.level = Int(percent) }
        s.volts = number("Voltage").flatMap { (1000...30000).contains($0) ? $0 / 1000 : nil }
        // int64Value preserves the signed current on Intel and Apple silicon.
        func current(_ key: String) -> Double? {
            (data[key] as? NSNumber).map { Double($0.int64Value) / 1000 }
                .flatMap { $0.isFinite && abs($0) <= 30 ? $0 : nil }
        }
        s.amps = current("InstantAmperage") ?? current("Amperage")
        s.batteryWatts = validWatts(s.volts.flatMap { v in s.amps.map { v * $0 } })
        if s.pluggedIn, let telemetry = data["PowerTelemetryData"] as? [String: Any] {
            s.inputWatts = validWatts((telemetry["SystemPowerIn"] as? NSNumber).map { $0.doubleValue / 1000 })
                .flatMap { $0 >= 0 ? $0 : nil }
        }
        let adapter = data["AdapterDetails"] as? [String: Any]
        s.adapterRating = (adapter?["Watts"] as? NSNumber)?.intValue
        s.cycles = (data["CycleCount"] as? NSNumber)?.intValue
        s.capacity = (data["AppleRawMaxCapacity"] as? NSNumber)?.intValue
        s.designCapacity = (data["DesignCapacity"] as? NSNumber)?.intValue
        if let capacity = s.capacity, let design = s.designCapacity, design > 100, capacity > 100 {
            s.health = min(100, max(0, Int((Double(capacity) / Double(design) * 100).rounded())))
        }
        return s
    }
    static func read() -> Self {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return Self() }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let data = properties?.takeRetainedValue() as? [String: Any] else { return Self() }
        return parse(data, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

struct BatteryMenuDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let detail: String
    let level: Int?
}
struct BatteryMenuAppEnergy: Identifiable, Equatable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let watts: Double
}
struct BatteryMenuPoint: Identifiable, Equatable, Sendable {
    var id: Date { date }
    let date: Date
    let level: Int
}
