/*
 * NotchFlow (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import IOKit
import IOKit.ps

/// Lightweight helper for querying macOS battery charging status and ETA.
final class MacBatteryManager {
    static let shared = MacBatteryManager()

    private init() {}

    struct BatteryStatus: Equatable, Sendable {
        let timeToFullMinutes: Int?
        let timeToEmptyMinutes: Int?
        let isCharging: Bool
        let isPluggedIn: Bool
        let percentage: Int?
    }

    struct BatteryDiagnostics: Equatable, Sendable {
        let cycleCount: Int?
        let voltageVolts: Double?
        let currentAmps: Double?
        let batteryPowerWatts: Double?
        let adapterWatts: Int?
        let designCapacityMAh: Int?
        let fullChargeCapacityMAh: Int?
        let calculatedHealthPercent: Int?

        static let unavailable = BatteryDiagnostics(
            cycleCount: nil,
            voltageVolts: nil,
            currentAmps: nil,
            batteryPowerWatts: nil,
            adapterWatts: nil,
            designCapacityMAh: nil,
            fullChargeCapacityMAh: nil,
            calculatedHealthPercent: nil
        )

        var hasBattery: Bool {
            cycleCount != nil || voltageVolts != nil || designCapacityMAh != nil
        }
    }

    struct SystemHealthReport: Equatable, Sendable {
        let condition: String?
        let maximumCapacityPercent: Int?
    }

    /// These read-only values use the same AppleSmartBattery properties that
    /// Sapphire's BatteryStatsReader/BatteryManager use. No privileged helper
    /// is needed; unsupported keys remain nil rather than becoming 0 or 100%.
    func currentDiagnostics() -> BatteryDiagnostics {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .unavailable }
        defer { IOObjectRelease(service) }

        func intValue(_ key: String) -> Int? {
            if let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0),
               let number = property.takeRetainedValue() as? NSNumber {
                return number.intValue
            }
            // Recent Apple silicon models expose raw capacities in BatteryData.
            guard let property = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0),
                  let data = property.takeRetainedValue() as? [String: Any] else { return nil }
            return (data[key] as? NSNumber)?.intValue
        }

        let voltageMV = intValue("Voltage").flatMap { $0 > 0 ? $0 : nil }
        let currentMA = intValue("Amperage")
        let voltage = voltageMV.map { Double($0) / 1_000 }
        let current = currentMA.map { Double($0) / 1_000 }
        let power = voltage.flatMap { volts in current.map { volts * $0 } }
        let design = intValue("DesignCapacity").flatMap { $0 > 100 ? $0 : nil }
        // On some Macs `MaxCapacity` is only a 0–100 charge percentage.
        // Prefer the raw mAh key and never mislabel a percent as mAh.
        let full = intValue("AppleRawMaxCapacity").flatMap { $0 > 100 ? $0 : nil }
            ?? intValue("NominalChargeCapacity").flatMap { $0 > 100 ? $0 : nil }
            ?? intValue("MaxCapacity").flatMap { $0 > 100 ? $0 : nil }
        let health = design.flatMap { design in
            full.map { min(100, max(0, Int((Double($0) / Double(design) * 100).rounded()))) }
        }

        var adapterWatts: Int?
        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            adapterWatts = (details["Watts"] as? NSNumber)?.intValue
        }

        return BatteryDiagnostics(
            cycleCount: intValue("CycleCount"),
            voltageVolts: voltage,
            currentAmps: current,
            batteryPowerWatts: power,
            adapterWatts: adapterWatts,
            designCapacityMAh: design,
            fullChargeCapacityMAh: full,
            calculatedHealthPercent: health
        )
    }

    /// Newer macOS releases can hide raw capacity keys while System
    /// Information still reports Apple's health estimate. Fetch only while
    /// the battery popover is open, never as a background polling process.
    func systemHealthReport() -> SystemHealthReport? {
        let process = Process()
        let output = Pipe()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-xml", "SPPowerDataType"]
        process.standardOutput = output
        process.standardError = Pipe()
        process.terminationHandler = { _ in termination.signal() }

        do { try process.run() } catch { return nil }
        guard termination.wait(timeout: .now() + 4) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let reports = plist as? [[String: Any]],
              let items = reports.first?["_items"] as? [[String: Any]],
              let battery = items.first(where: { $0["_name"] as? String == "spbattery_information" }),
              let health = battery["sppower_battery_health_info"] as? [String: Any] else {
            return nil
        }

        let condition = health["sppower_battery_health"] as? String
        let capacityText = health["sppower_battery_health_maximum_capacity"] as? String
        let capacityNumber = capacityText.flatMap { Int($0.filter(\.isNumber)) }
        return SystemHealthReport(
            condition: condition,
            maximumCapacityPercent: capacityNumber.flatMap { (0...100).contains($0) ? $0 : nil }
        )
    }

    func currentStatus() -> BatteryStatus {
        guard let sourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourcesList = IOPSCopyPowerSourcesList(sourcesInfo)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryStatus(timeToFullMinutes: nil, timeToEmptyMinutes: nil, isCharging: false, isPluggedIn: false, percentage: nil)
        }

        for source in sourcesList {
            guard let description = IOPSGetPowerSourceDescription(sourcesInfo, source)?.takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else {
                continue
            }

            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let powerSource = description[kIOPSPowerSourceStateKey] as? String
            let isPluggedIn = powerSource == kIOPSACPowerValue
            let timeToFull = positiveMinutes(description[kIOPSTimeToFullChargeKey])
            var timeToEmpty = positiveMinutes(description[kIOPSTimeToEmptyKey])
            if timeToEmpty == nil, !isPluggedIn {
                let estimate = IOPSGetTimeRemainingEstimate()
                if estimate != kIOPSTimeRemainingUnknown,
                   estimate != kIOPSTimeRemainingUnlimited,
                   estimate > 0 {
                    timeToEmpty = Int((estimate / 60).rounded())
                }
            }
            let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int
            let maxCapacity = description[kIOPSMaxCapacityKey] as? Int

            let percentage: Int?
            if let current = currentCapacity, let max = maxCapacity, max > 0 {
                percentage = (current * 100) / max
            } else {
                percentage = nil
            }

            return BatteryStatus(
                timeToFullMinutes: timeToFull,
                timeToEmptyMinutes: timeToEmpty,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                percentage: percentage
            )
        }

        return BatteryStatus(timeToFullMinutes: nil, timeToEmptyMinutes: nil, isCharging: false, isPluggedIn: false, percentage: nil)
    }

    func formattedTimeToFullCharge() -> String? {
        let status = currentStatus()
        guard status.isCharging, let minutes = status.timeToFullMinutes, minutes > 0 else {
            return nil
        }

        return Self.format(minutes: minutes)
    }

    func formattedTimeToEmpty() -> String? {
        let status = currentStatus()
        guard !status.isPluggedIn, let minutes = status.timeToEmptyMinutes, minutes > 0 else {
            return nil
        }

        return Self.format(minutes: minutes)
    }

    private func positiveMinutes(_ value: Any?) -> Int? {
        if let int = value as? Int, int > 0 { return int }
        if let number = value as? NSNumber, number.intValue > 0 { return number.intValue }
        return nil
    }

    static func format(minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if hours > 0 {
            return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
        }
        return "\(remainingMinutes)m"
    }
}
