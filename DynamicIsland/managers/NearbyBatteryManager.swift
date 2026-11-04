import AppKit
import CoreBluetooth
import Combine
import Defaults

struct NearbyBatteryCandidate: Identifiable, Equatable {
    let id: String
    let name: String
}
/// Duty-cycled discovery; only user-selected peripherals are connected. Each
/// read disconnects immediately and has a timeout, so it cannot hold sleep open.
@MainActor final class NearbyBatteryManager: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = NearbyBatteryManager()
    @Published private(set) var candidates: [NearbyBatteryCandidate] = []
    @Published private(set) var readings: [OrbitBatteryDevice] = []
    @Published private(set) var status = "Bluetooth discovery is off"
    private var central: CBCentralManager?
    private var candidateRecords: [String: NearbyBatteryCandidate] = [:]
    private var peripherals: [String: CBPeripheral] = [:]
    private var unsupported = Set<String>()
    private var groupAttempts: [String: Date] = [:]
    private var attempts: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]
    private var timeouts: [String: DispatchWorkItem] = [:]
    private var scanTimer: Timer?
    private var stopTask: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    func start() {
        guard !started else { return }; started = true
        Defaults.publisher(.orbitNearbyBatteriesEnabled).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configure() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.configure() }.store(in: &subscriptions)
        Defaults.publisher(.orbitCombineDuplicateDevices).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncCandidates() }.store(in: &subscriptions)
        configure()
    }
    private func configure() {
        stop()
        guard Defaults[.orbitNearbyBatteriesEnabled] else { status = "Bluetooth discovery is off"; readings = []; return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scan()
    }
    private func stop() {
        scanTimer?.invalidate(); scanTimer = nil
        stopTask?.cancel(); stopTask = nil
        central?.stopScan()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        for peripheral in peripherals.values where peripheral.state != .disconnected { central?.cancelPeripheralConnection(peripheral) }
    }
    func scan() {
        guard Defaults[.orbitNearbyBatteriesEnabled], !LockScreenManager.shared.isLocked,
              let central, central.state == .poweredOn else { return }
        let now = Date()
        for id in Array(peripherals.keys) where now.timeIntervalSince(lastSeen[id] ?? .distantPast) > 900 && peripherals[id]?.state == .disconnected {
            peripherals.removeValue(forKey: id); lastSeen.removeValue(forKey: id); attempts.removeValue(forKey: id)
        }
        candidateRecords = candidateRecords.filter { peripherals[$0.key] != nil }
        syncCandidates()
        readings.removeAll { now.timeIntervalSince($0.observedAt) > 180 }
        status = "Looking for battery-capable devices…"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        for peripheral in central.retrieveConnectedPeripherals(withServices: [batteryService]) {
            remember(peripheral, name: peripheral.name ?? "Bluetooth device")
        }
        stopTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.central?.stopScan(); self?.status = "Scanning briefly once a minute"
            }
        }
        stopTask = work; DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
    func tracks(_ id: String) -> Bool {
        if Defaults[.orbitTrackedNearbyDevices].contains(id) { return true }
        guard Defaults[.orbitCombineDuplicateDevices], let name = candidateRecords[id]?.name,
              let key = OrbitDeviceReconciler.phoneKey(name: name) else { return false }
        return Defaults[.orbitTrackedNearbyGroups][key] != nil
    }
    func track(_ id: String, enabled: Bool) {
        var ids = Set(Defaults[.orbitTrackedNearbyDevices])
        var groups = Defaults[.orbitTrackedNearbyGroups]
        let group = candidateRecords[id].flatMap { OrbitDeviceReconciler.phoneKey(name: $0.name) }
        if enabled {
            ids.insert(id)
            if Defaults[.orbitCombineDuplicateDevices], let group { groups[group] = Array(Set((groups[group] ?? []) + [id])).sorted() }
        } else {
            ids.remove(id)
            if let group {
                ids.subtract(groups.removeValue(forKey: group) ?? [])
                for (candidateID, candidate) in candidateRecords where OrbitDeviceReconciler.phoneKey(name: candidate.name) == group {
                    ids.remove(candidateID)
                    readings.removeAll { $0.id == "nearby:" + candidateID }
                    if let peripheral = peripherals[candidateID] { central?.cancelPeripheralConnection(peripheral) }
                }
            }
            readings.removeAll { $0.id == "nearby:" + id }
            if let peripheral = peripherals[id] { central?.cancelPeripheralConnection(peripheral) }
        }
        Defaults[.orbitTrackedNearbyGroups] = groups
        Defaults[.orbitTrackedNearbyDevices] = ids.sorted()
        if enabled, let peripheral = peripherals[id] {
            unsupported.remove(id); attempts.removeValue(forKey: id)
            if let group { groupAttempts.removeValue(forKey: group) }
            read(peripheral)
        }
        syncCandidates(); OrbitBatteryHub.shared.refresh()
        objectWillChange.send()
    }
    private func syncCandidates() {
        let tracked = Set(candidateRecords.keys.filter { tracks($0) })
        let visible = OrbitDeviceReconciler.discoveryCandidates(Array(candidateRecords.values), lastSeen: lastSeen,
            tracked: tracked, combine: Defaults[.orbitCombineDuplicateDevices], at: Date())
        if candidates != visible { candidates = visible }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scan()
        case .unauthorized: status = "Allow Orbit in System Settings → Privacy & Security → Bluetooth"
        case .poweredOff: status = "Bluetooth is off"; readings = []
        default: status = "Bluetooth is not available"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard RSSI.intValue >= -85, let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let apple = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { bytes in
            bytes.count > 2 && bytes[0] == 0x4c && bytes[1] == 0 && [0x10, 0x0c].contains(bytes[2])
        } ?? false
        guard apple || services.contains(batteryService) || tracks(peripheral.identifier.uuidString) else { return }
        remember(peripheral, name: name)
    }
    private func remember(_ peripheral: CBPeripheral, name: String) {
        let id = peripheral.identifier.uuidString
        guard peripherals.count < 64 || peripherals[id] != nil else { return }
        peripherals[id] = peripheral; lastSeen[id] = Date()
        let candidate = NearbyBatteryCandidate(id: id, name: String(name.prefix(80)))
        candidateRecords[id] = candidate
        if Defaults[.orbitCombineDuplicateDevices], let key = OrbitDeviceReconciler.phoneKey(name: candidate.name) {
            var groups = Defaults[.orbitTrackedNearbyGroups]
            if Defaults[.orbitTrackedNearbyDevices].contains(id) || groups[key] != nil {
                let combined = Array(Set((groups[key] ?? []) + [id])).sorted()
                if groups[key] != combined { groups[key] = combined; Defaults[.orbitTrackedNearbyGroups] = groups }
            }
        }
        syncCandidates()
        if tracks(id) { read(peripheral) }
    }
    private func read(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        guard tracks(id), !unsupported.contains(id), timeouts[id] == nil, peripheral.state != .connecting, peripheral.state != .disconnecting, Date().timeIntervalSince(attempts[id] ?? .distantPast) > 55 else { return }
        if Defaults[.orbitCombineDuplicateDevices], let name = candidateRecords[id]?.name,
           let key = OrbitDeviceReconciler.phoneKey(name: name) {
            guard Date().timeIntervalSince(groupAttempts[key] ?? .distantPast) > 55 else { return }
            groupAttempts[key] = Date()
        }
        attempts[id] = Date(); peripheral.delegate = self
        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            MainActor.assumeIsolated { if let peripheral { self?.finish(peripheral) } }
        }
        timeouts[id] = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        central?.connect(peripheral, options: nil)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices([batteryService]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { finish(peripheral) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        timeouts.removeValue(forKey: peripheral.identifier.uuidString)?.cancel()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == batteryService }) else {
            if error == nil { unsupported.insert(peripheral.identifier.uuidString) }
            finish(peripheral); return
        }
        peripheral.discoverCharacteristics([batteryLevel], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == batteryLevel }) else {
            if error == nil { unsupported.insert(peripheral.identifier.uuidString) }
            finish(peripheral); return
        }
        peripheral.readValue(for: characteristic)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        defer { finish(peripheral) }
        guard error == nil, characteristic.uuid == batteryLevel, let value = Self.decodeLevel(characteristic.value), tracks(peripheral.identifier.uuidString) else { return }
        let id = "nearby:" + peripheral.identifier.uuidString
        let name = candidates.first { $0.id == peripheral.identifier.uuidString }?.name ?? peripheral.name ?? "Bluetooth device"
        let symbol = name.lowercased().contains("ipad") ? "ipad" : name.lowercased().contains("iphone") ? "iphone" : "wave.3.right"
        let record = OrbitBatteryDevice(id: id, name: name, symbol: symbol, level: value, charging: false,
            connected: true, observedAt: Date(), detail: "Bluetooth · charging state unavailable")
        readings.removeAll { $0.id == id }; readings.append(record)
        OrbitBatteryHub.shared.refresh()
    }
    private func finish(_ peripheral: CBPeripheral) {
        timeouts.removeValue(forKey: peripheral.identifier.uuidString)?.cancel()
        central?.cancelPeripheralConnection(peripheral)
    }
    nonisolated static func decodeLevel(_ data: Data?) -> Int? {
        guard let data, data.count == 1, let value = data.first, value <= 100 else { return nil }
        return Int(value)
    }
}
