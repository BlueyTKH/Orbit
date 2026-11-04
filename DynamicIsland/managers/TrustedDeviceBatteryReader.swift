import Foundation
import Darwin
import CryptoKit

/// Optional macOS MobileDevice access. No pairing, provisioning, app installation,
/// wireless-sync changes or device writes. Only already-trusted sessions are read.
enum TrustedDeviceBatteryReader {
    private static let library = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_LAZY)
    private typealias List = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Operation = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias CopyValue = @convention(c) (UnsafeRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyID = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let symbol = dlsym(library, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
    static func read() -> [OrbitBatteryDevice] {
        guard let list = function("AMDCreateDeviceList", as: List.self),
              let connect = function("AMDeviceConnect", as: Operation.self),
              let paired = function("AMDeviceIsPaired", as: Operation.self),
              let validate = function("AMDeviceValidatePairing", as: Operation.self),
              let start = function("AMDeviceStartSession", as: Operation.self),
              let stop = function("AMDeviceStopSession", as: Operation.self),
              let disconnect = function("AMDeviceDisconnect", as: Operation.self),
              let copy = function("AMDeviceCopyValue", as: CopyValue.self),
              let identifier = function("AMDeviceCopyDeviceIdentifier", as: CopyID.self),
              let devices = list()?.takeRetainedValue() else { return [] }
        var results: [String: OrbitBatteryDevice] = [:]
        for index in 0..<min(16, CFArrayGetCount(devices)) {
            guard let device = CFArrayGetValueAtIndex(devices, index), connect(device) == 0 else { continue }
            defer { _ = disconnect(device) }
            guard paired(device) == 1, validate(device) == 0, start(device) == 0 else { continue }
            defer { _ = stop(device) }
            func value(_ key: String, domain: String? = nil) -> Any? {
                copy(device, domain.map { $0 as CFString }, key as CFString)?.takeRetainedValue()
            }
            guard let kind = value("DeviceClass") as? String, ["iPhone", "iPad"].contains(kind),
                  let identity = identifier(device)?.takeRetainedValue() as String?,
                  let level = percentage(value("BatteryCurrentCapacity", domain: "com.apple.mobile.battery")) else { continue }
            let id = "mobile:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let name = String((value("DeviceName") as? String ?? kind)
                .components(separatedBy: .controlCharacters).joined(separator: " ").prefix(80))
            results[id] = OrbitBatteryDevice(id: id, name: name.isEmpty ? kind : name,
                symbol: kind == "iPad" ? "ipad" : "iphone", level: level,
                charging: value("BatteryIsCharging", domain: "com.apple.mobile.battery") as? Bool ?? false,
                connected: true, observedAt: Date(), detail: "Trusted device")
        }
        return results.values.sorted { $0.id < $1.id }
    }
    static func percentage(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue, (0...100).contains(number.doubleValue) else { return nil }
        return number.intValue
    }
}
