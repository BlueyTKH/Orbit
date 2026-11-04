import AppKit
import Combine
import Defaults
import WidgetKit
import IOBluetooth
import CryptoKit

/// Collectors run in the app; widgets only read the small shared snapshot.
@MainActor final class OrbitBatteryHub: ObservableObject {
    static let shared = OrbitBatteryHub()
    @Published private(set) var devices: [OrbitBatteryDevice] = []
    @Published private(set) var storageError: String?
    private var mobile: [OrbitBatteryDevice] = []
    private let worker = DispatchQueue(label: "com.kayhsen.Orbit.devices", qos: .utility)
    private var timer: Timer?
    private var started = false
    private var reading = false
    private var subscriptions = Set<AnyCancellable>()
    private var lastReload = Date.distantPast
    private var lastSignature = ""
    func start() {
        guard !started else { return }; started = true
        Defaults.publisher(.orbitTrustedDevicesEnabled).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        Defaults.publisher(.orbitCombineDuplicateDevices).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
    }
    func refresh() {
        guard !reading else { return }; reading = true
        let readPhones = Defaults[.orbitTrustedDevicesEnabled] && !LockScreenManager.shared.isLocked
        worker.async { [weak self] in
            let phones = readPhones ? TrustedDeviceBatteryReader.read() : []
            let power = BatteryMenuSnapshot.read()
            let accessories = AccessorySystemPowerSource.read() ?? [:]
            Task { @MainActor in
                guard let self else { return }; self.reading = false
                // A setting may have changed while a private device query was pending.
                self.mobile = Defaults[.orbitTrustedDevicesEnabled] ? phones : []
                self.publish(power: power, accessories: accessories)
            }
        }
    }
    private func publish(power: BatteryMenuSnapshot, accessories: [String: [Int]]) {
        let now = Date()
        var current = mobile + NearbyBatteryManager.shared.readings.filter { $0.usableLevel(at: now) != nil }
        if let level = power.level {
            current.append(.init(id: "mac", name: Host.current().localizedName ?? "This Mac", symbol: "laptopcomputer",
                level: level, charging: power.charging, connected: true, observedAt: now, detail: power.state))
        }
        for pod in BluetoothAudioManager.shared.airPodsBatteryReadings() {
            let components: [(String, Int?, Bool)] = pod.left != nil || pod.right != nil
                ? [("Left", pod.left, pod.leftCharging), ("Right", pod.right, pod.rightCharging)]
                : [("", pod.main, pod.mainCharging)]
            for (part, level, charging) in components where level != nil {
                current.append(.init(id: Self.id(pod.address + ":" + part), name: pod.name + (part.isEmpty ? "" : " · " + part),
                    symbol: pod.symbol, level: level, charging: charging, connected: true,
                    observedAt: pod.observedAt, detail: part.isEmpty ? "AirPods" : part + " earbud"))
            }
        }
        // Only currently connected peripherals are eligible; never borrow a cached
        // percentage merely because a previously paired device has the same name.
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }
        for device in paired {
            guard let name = device.name, let address = device.addressString,
                  (device.classOfDevice >> 8) & 0x1F == 5 || ["mouse", "keyboard", "trackpad"].contains(where: { name.lowercased().contains($0) }) else { continue }
            let matches = paired.filter { $0.name == name }
            let level = matches.count == 1 && accessories[name]?.count == 1 ? accessories[name]?.first : nil
            let symbol = name.lowercased().contains("trackpad") ? "magictrackpad" : name.lowercased().contains("keyboard") ? "keyboard" : "computermouse.fill"
            current.append(.init(id: Self.id(address), name: name, symbol: symbol, level: level,
                charging: false, connected: true, observedAt: now, detail: level == nil ? "Battery unavailable" : "Bluetooth"))
        }
        current += BluetoothAudioManager.shared.orbitAirPodsCases()
        let used = Set(current.map(\.id))
        for device in BluetoothAudioManager.shared.connectedDevices where !device.deviceType.isAirPods {
            let id = Self.id(device.address)
            guard !used.contains(id) else { continue }
            current.append(.init(id: id, name: device.name, symbol: "headphones", level: device.batteryLevel,
                charging: false, connected: true, observedAt: now, detail: "Bluetooth audio"))
        }
        let combine = Defaults[.orbitCombineDuplicateDevices]
        let previous = devices.isEmpty ? (OrbitBatteryStore.read()?.devices ?? []) : devices
        let known = OrbitDeviceReconciler.reconcile(previous, combine: combine, at: now)
        var mergedCurrent = OrbitDeviceReconciler.reconcile(current, combine: combine, at: now)
        for index in mergedCurrent.indices {
            if let old = known.first(where: { $0.id == mergedCurrent[index].id }), mergedCurrent[index].id.hasPrefix("phone:") {
                let aliases = (old.aliases ?? []) + (mergedCurrent[index].aliases ?? [])
                var seen = Set<String>()
                mergedCurrent[index].aliases = Array(aliases.filter { seen.insert($0).inserted }.prefix(256))
            }
        }
        let ids = Set(mergedCurrent.flatMap { [$0.id] + ($0.aliases ?? []) })
        let offline = known.filter { !ids.contains($0.id) && (combine || !$0.id.hasPrefix("phone:")) && now.timeIntervalSince($0.observedAt) < 7 * 86400 }
            .prefix(32).map { old -> OrbitBatteryDevice in
                var value = old; value.connected = false; value.level = nil; value.detail = "Offline"; return value
            }
        let merged = (mergedCurrent + offline).sorted { $0.id < $1.id }
        if devices != merged { devices = merged }
        let signature = merged.map { "\($0.id):\($0.level ?? -1):\($0.charging):\($0.connected)" }.joined(separator: "|")
        let reload = signature != lastSignature && now.timeIntervalSince(lastReload) > 60
        if reload { lastReload = now; lastSignature = signature }
        let snapshot = OrbitBatterySnapshot(writtenAt: now, devices: merged)
        worker.async { [weak self] in
            do {
                try OrbitBatteryStore.write(snapshot)
                if reload { WidgetCenter.shared.reloadTimelines(ofKind: OrbitBatteryStore.widgetKind) }
                Task { @MainActor in self?.storageError = nil }
            } catch {
                Task { @MainActor in self?.storageError = "Widgets cannot access their shared battery data." }
            }
        }
    }
    static func id(_ value: String) -> String {
        "bluetooth:" + SHA256.hash(data: Data(value.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
