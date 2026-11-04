import Foundation
import IOKit.ps
import Darwin

enum AccessoryKind: String { case airPods, mouse }
struct AccessoryConnectionEvent: Equatable {
    let address: String
    let name: String
    let symbol: String
    let kind: AccessoryKind
    let connected: Bool
    var left: Int?
    var right: Int?
    var main: Int?
    var artworkModel: AirPodsArtworkModel? = nil
    var status: String { connected ? "Connected" : "Disconnected" }
    var detail: String {
        let components = [left.map { "Left \($0)%" }, right.map { "Right \($0)%" }].compactMap { $0 }
        let value = components.isEmpty ? main.map { "\($0)%" } : components.joined(separator: "  ·  ")
        guard let value else { return connected ? "Battery unavailable" : "" }
        return connected ? value : "Last reported: \(value)"
    }
    func updating(_ reading: AirPodsBatteryReading?) -> Self {
        guard let reading, reading.address == address else { return self }
        var result = self
        result.left = reading.left; result.right = reading.right; result.main = reading.main
        return result
    }
    static let airPodsPreview = Self(address: "preview-airpods", name: "AirPods Pro", symbol: "airpods.pro",
        kind: .airPods, connected: true, left: 50, right: 100)
    static let mousePreview = Self(address: "preview-mouse", name: "Bluetooth Mouse", symbol: "computermouse.fill",
        kind: .mouse, connected: true, main: 98)
}

enum AccessoryConnectionLayout {
    static let wingWidth: CGFloat = 108
    static let outerPadding: CGFloat = 20
    static let cameraClearance: CGFloat = 8
    static func surface(closed: CGSize, style: BatteryNotificationStyle) -> CGSize {
        CGSize(width: closed.width + (style == .compact ? 2 * (wingWidth + outerPadding) : 190),
               height: closed.height + (style == .compact ? 0 : 88))
    }
}

/// The power-source report includes BLE mouse batteries missing from SPBluetooth.
/// Only a unique, exact connected name may acquire a reading.
enum AccessoryPowerReadings {
    static func parse(_ data: Data) -> [String: [Int]] {
        // pmset may encode accessory names as Mac Roman, even in a UTF-8
        // locale. One accented name must not discard the other batteries.
        parse(String(data: data, encoding: .utf8) ?? String(data: data, encoding: .macOSRoman) ?? "")
    }
    static func parse(_ output: String) -> [String: [Int]] {
        let regex = try! NSRegularExpression(pattern: #"^\s*-\s*(.+?)\s+\(id=[^\n]+?\)\s*(\d{1,3})%;"#, options: [.anchorsMatchLines])
        let text = output as NSString
        var result: [String: [Int]] = [:]
        for match in regex.matches(in: output, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let level = AirPodsBatteryReading.percentage(text.substring(with: match.range(at: 2))) else { continue }
            result[name, default: []].append(level)
        }
        return result
    }
    static func level(name: String, connectedNames: [String], readings: [String: [Int]]) -> Int? {
        guard connectedNames.filter({ $0 == name }).count == 1,
              let levels = readings[name], levels.count == 1 else { return nil }
        return levels.first
    }
}


/// Connection edges are independent of battery fetches and duplicate signals.
struct MouseConnectionPresence {
    private var addresses = Set<String>()
    private var hasBaseline = false
    mutating func arrivals(in current: Set<String>) -> Set<String> {
        let arrived = hasBaseline ? current.subtracting(addresses) : []
        addresses = current; hasBaseline = true
        return arrived
    }
    mutating func disconnected(_ address: String) { addresses.remove(address) }
    mutating func resetBaseline() { hasBaseline = false }
}

/// Read the same accessory snapshot used by pmset, without launching a process.
/// The accessory selector is not in the public SDK; resolve it optionally and
/// retain the existing pmset fallback when it is unavailable on a future OS.
enum AccessorySystemPowerSource {
    private static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private typealias CopySources = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    static func read() -> [String: [Int]]? {
        guard let library, let symbol = dlsym(library, "IOPSCopyPowerSourcesByType") else { return nil }
        let copySources = unsafeBitCast(symbol, to: CopySources.self)
        guard let info = copySources(4)?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return decode(descriptions)
    }
    static func decode(_ descriptions: [[String: Any]]) -> [String: [Int]] {
        var readings: [String: [Int]] = [:]
        for source in descriptions {
            guard source["Type"] as? String == "Accessory Source",
                  (source["Is Present"] as? NSNumber)?.boolValue != false,
                  let name = source["Name"] as? String, !name.isEmpty,
                  let current = source["Current Capacity"] as? NSNumber,
                  let maximum = source["Max Capacity"] as? NSNumber,
                  CFGetTypeID(current) != CFBooleanGetTypeID(),
                  CFGetTypeID(maximum) != CFBooleanGetTypeID(),
                  current.doubleValue.isFinite, maximum.doubleValue.isFinite,
                  maximum.doubleValue > 0, current.doubleValue >= 0,
                  current.doubleValue <= maximum.doubleValue else { continue }
            let percent = Int((100 * current.doubleValue / maximum.doubleValue).rounded())
            readings[name, default: []].append(percent)
        }
        return readings
    }
}

/// Only the first resolved battery result starts the user's reading time.
struct MouseBatteryPresentationClock {
    static let unavailableTimeout: TimeInterval = 15
    let duration: TimeInterval
    private(set) var waitingForBattery: Bool
    private var hasMeasuredBattery: Bool
    init(duration: Int, hasBattery: Bool) {
        self.duration = TimeInterval(min(max(duration, 1), 60))
        waitingForBattery = !hasBattery
        hasMeasuredBattery = hasBattery
    }
    var initialHideDelay: TimeInterval { waitingForBattery ? .infinity : duration }
    mutating func resolveBattery() -> TimeInterval? {
        guard !hasMeasuredBattery else { return nil }
        hasMeasuredBattery = true
        waitingForBattery = false
        return duration
    }
    mutating func resolveUnavailable() -> TimeInterval? {
        guard waitingForBattery else { return nil }
        waitingForBattery = false
        return duration
    }
}

/// The artwork family is retained separately because Pro 3 shares its SF symbol.
enum AirPodsArtworkModel: String, CaseIterable {
    case classic = "Classic", third = "Third", fourth = "Fourth", pro = "Pro", proThird = "ProThird", max = "Max"
    var assetName: String { "AirPodsCase" + rawValue }
    static let duration: TimeInterval = 3.0
    static let frameCount = 64
    static func resolve(symbol: String, name: String) -> Self {
        let label = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if symbol == "airpodsmax" { return .max }
        if symbol.contains("pro") {
            return label.contains("pro3") || label.contains("pro3rd") ? .proThird : .pro
        }
        if symbol.contains("gen4") { return .fourth }
        if symbol.contains("gen3") { return .third }
        return .classic
    }
    static func frame(elapsed: TimeInterval, connected: Bool) -> Int {
        let time = elapsed.isFinite ? Swift.min(Swift.max(elapsed, 0), duration) : 0
        let frame = Swift.min(Int(time / duration * Double(frameCount-1)), frameCount-1)
        return connected ? frame : frameCount-1-frame
    }
}
