import AppKit
import Combine
import Defaults
import IOBluetooth
import notify

/// Stable event snapshots keep disconnection data visible after the live device is gone.
@MainActor
final class AccessoryConnectionManager: NSObject, ObservableObject {
    static let shared = AccessoryConnectionManager()
    @Published private(set) var connectedMice: [AccessoryConnectionEvent] = []
    private var started = false
    private var activeSession = true
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var knownAirPods: [String: AccessoryConnectionEvent] = [:]
    private var mice: [String: AccessoryConnectionEvent] = [:]
    private var mousePresence = MouseConnectionPresence()
    private var mouseConnectNotification: IOBluetoothUserNotification?
    private var mouseDisconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var mouseEventRetryTask: Task<Void, Never>?
    private var powerReadings: [String: [Int]] = [:]
    private var lastPowerRefresh = Date.distantPast
    private var lastMousePoll = Date.distantPast
    private var refreshingPower = false
    private var accessoryPowerNotificationTokens: [Int32] = []
    private var mouseBatteryRetryUntil: [String: Date] = [:]
    private let worker = DispatchQueue(label: "com.kayhsen.NotchFlow.accessory.power", qos: .utility)
    private var pending: [(event: AccessoryConnectionEvent, ready: Date, expires: Date)] = []
    private var connectionTasks: [String: Task<Void, Never>] = [:]
    private var awake: Bool { activeSession && !LockScreenManager.shared.isLocked }

    override init() { super.init() }

    func start() {
        guard !started else { return }; started = true
        BluetoothAudioManager.shared.$connectedDevices.sink { [weak self] _ in
            Task { @MainActor in self?.rememberAirPods() }
        }.store(in: &subscriptions)
        LockScreenManager.shared.$isLocked.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.sessionChanged() }
        }.store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.activeSession = false; self?.sessionChanged() }
            }.store(in: &subscriptions)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.activeSession = true; self?.sessionChanged() }
            }.store(in: &subscriptions)
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        // These read-only notify(3) topics are published by powerd when an
        // accessory battery attaches or changes. Never wait for the 30s refresh.
        for topic in ["com.apple.system.accpowersources.attach", "com.apple.system.accpowersources.timeremaining",
                      "com.apple.system.accpowersources.source"] {
            var token: Int32 = 0
            if notify_register_dispatch(topic, &token, .main, { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.awake, Defaults[.showMouseConnections] else { return }
                    self.refreshPower()
                }
            }) == NOTIFY_STATUS_OK { accessoryPowerNotificationTokens.append(token) }
        }
        tick() // Establish a silent startup baseline before registering callbacks.
        mouseConnectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
            selector: #selector(mouseDidConnect(_:device:)))
        // Some BLE devices publish this signal before IOBluetooth's connected
        // property catches up. Retry that handoff briefly, without radio scans.
        for name in ["IOBluetoothDeviceConnectedNotification", "IOBluetoothDeviceDisconnectedNotification"] {
            DistributedNotificationCenter.default().publisher(for: Notification.Name(name)).sink { [weak self] _ in
                Task { @MainActor in self?.mouseConnectionSignal() }
            }.store(in: &subscriptions)
        }
    }
    @objc nonisolated private func mouseDidConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Task { @MainActor [weak self] in
            guard let self, self.isMouse(device) else { return }
            self.mouseConnectionSignal()
        }
    }
    @objc nonisolated private func mouseDidDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Task { @MainActor [weak self] in
            guard let self, let address = device.addressString else { return }
            if !BatteryStatusViewModel.shared.isAccessoryConnectionPreview {
                BatteryStatusViewModel.shared.dismissAccessoryConnection(address: address)
            }
            self.mousePresence.disconnected(address)
            self.mice.removeValue(forKey: address)
            self.mouseBatteryRetryUntil.removeValue(forKey: address)
            self.updateConnectedMice(self.connectedMice.filter { $0.address != address })
            self.pending.removeAll { $0.event.address == address }
            self.connectionTasks.removeValue(forKey: address)?.cancel()
            self.mouseDisconnectNotifications.removeValue(forKey: address)?.unregister()
        }
    }
    private func mouseConnectionSignal() {
        guard awake, Defaults[.showMouseConnections] else { return }
        pollMice()
        mouseEventRetryTask?.cancel()
        mouseEventRetryTask = Task { [weak self] in
            for delay in [150, 300] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled, self.awake, Defaults[.showMouseConnections] else { return }
                self.pollMice()
            }
        }
    }
    private func isMouse(_ device: IOBluetoothDevice) -> Bool {
        let major = (device.classOfDevice >> 8) & 0x1F
        return (major == 5 && device.classOfDevice & 0x80 != 0)
            || (device.name ?? "").localizedCaseInsensitiveContains("mouse")
    }
    private func sessionChanged() {
        pending.removeAll(); connectionTasks.values.forEach { $0.cancel() }; connectionTasks.removeAll()
        mousePresence.resetBaseline()
        mouseBatteryRetryUntil.removeAll()
        mouseEventRetryTask?.cancel()
        if !awake { BatteryStatusViewModel.shared.dismissAccessoryConnection() }
        else { lastMousePoll = .distantPast; tick() }
    }
    private func artworkModel(_ device: BluetoothAudioDevice) -> AirPodsArtworkModel {
        if device.deviceType == .airpodsPro3 { return .proThird }
        return .resolve(symbol: device.deviceType.sfSymbol, name: device.name)
    }
    private func rememberAirPods() {
        for device in BluetoothAudioManager.shared.connectedDevices where device.deviceType.isAirPods {
            let old = knownAirPods[device.address]
            let event = AccessoryConnectionEvent(address: device.address, name: device.name, symbol: device.deviceType.sfSymbol,
                kind: .airPods, connected: true, left: old?.left, right: old?.right, main: old?.main, artworkModel: artworkModel(device))
            knownAirPods[device.address] = event.updating(BluetoothAudioManager.shared.airPodsBatteryReadings().first { $0.address == device.address })
        }
    }
    func airPodsConnected(_ device: BluetoothAudioDevice) {
        start()
        guard awake, Defaults[.showBluetoothDeviceConnections] else { return }
        connectionTasks[device.address]?.cancel()
        pending.removeAll { $0.event.address == device.address }
        BluetoothAudioManager.shared.refreshConnectedDeviceBatteries()
        connectionTasks[device.address] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard let self, !Task.isCancelled, self.awake,
                  BluetoothAudioManager.shared.connectedDevices.contains(where: { $0.address == device.address }) else { return }
            self.rememberAirPods()
            let event = self.knownAirPods[device.address] ?? AccessoryConnectionEvent(address: device.address,
                name: device.name, symbol: device.deviceType.sfSymbol, kind: .airPods, connected: true, artworkModel: self.artworkModel(device))
            self.enqueue(event); self.connectionTasks.removeValue(forKey: device.address)
        }
    }
    func airPodsDisconnected(_ device: BluetoothAudioDevice) {
        connectionTasks.removeValue(forKey: device.address)?.cancel()
        pending.removeAll { $0.event.address == device.address }
        guard awake, Defaults[.showBluetoothDeviceConnections], Defaults[.showAirPodsDisconnections] else { return }
        let old = knownAirPods[device.address]
        enqueue(AccessoryConnectionEvent(address: device.address, name: device.name, symbol: device.deviceType.sfSymbol,
            kind: .airPods, connected: false, left: old?.left, right: old?.right, main: old?.main,
            artworkModel: old?.artworkModel ?? artworkModel(device)))
    }
    private func enqueue(_ event: AccessoryConnectionEvent, delay: TimeInterval = 0) {
        guard awake else { return }
        pending.removeAll { $0.event.address == event.address }
        pending.append((event, Date().addingTimeInterval(delay), Date().addingTimeInterval(15)))
        deliverPending()
    }
    private func tick() {
        guard awake else { return }
        if Defaults[.showMouseConnections] {
            if Date().timeIntervalSince(lastMousePoll) >= 1 { lastMousePoll = Date(); pollMice() }
            let awaitingBattery = mouseBatteryRetryUntil.values.contains { $0 > Date() }
            if Date().timeIntervalSince(lastPowerRefresh) >= (awaitingBattery ? 0.5 : 30) { refreshPower() }
        } else {
            pending.removeAll { $0.event.kind == .mouse }; mousePresence.resetBaseline()
            if BatteryStatusViewModel.shared.activeAccessoryConnection?.kind == .mouse {
                BatteryStatusViewModel.shared.dismissAccessoryConnection()
            }
        }
        deliverPending()
    }
    private func pollMice() {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        // A tiny in-process snapshot is available before building the popup.
        // Read every connection/power signal, even if the last query was empty.
        if let readings = AccessorySystemPowerSource.read() {
            powerReadings = readings; lastPowerRefresh = Date()
        }
        let connected = paired.filter { $0.isConnected() && isMouse($0) }
        let names = connected.compactMap(\.name)
        var updated: [String: AccessoryConnectionEvent] = [:]
        for device in connected {
            guard let address = device.addressString, let name = device.name else { continue }
            updated[address] = AccessoryConnectionEvent(address: address, name: name, symbol: "computermouse.fill", kind: .mouse,
                connected: true, main: Date().timeIntervalSince(lastPowerRefresh) <= 30
                    ? AccessoryPowerReadings.level(name: name, connectedNames: names, readings: powerReadings) : nil)
            if mouseDisconnectNotifications[address] == nil {
                mouseDisconnectNotifications[address] = device.register(forDisconnectNotification: self,
                    selector: #selector(mouseDidDisconnect(_:device:)))
            }
        }
        let arrived = mousePresence.arrivals(in: Set(updated.keys))
        // Commit the current device before enqueue can synchronously present it.
        mice = updated; updateConnectedMice(Array(updated.values))
        for address in Array(mouseDisconnectNotifications.keys) where updated[address] == nil {
            mouseDisconnectNotifications.removeValue(forKey: address)?.unregister()
        }
        mouseBatteryRetryUntil = mouseBatteryRetryUntil.filter {
            $0.value > Date() && updated[$0.key] != nil && updated[$0.key]?.main == nil
        }
        for address in arrived {
            guard let event = updated[address] else { continue }
            if event.main == nil { mouseBatteryRetryUntil[address] = Date().addingTimeInterval(10) }
            if Date().timeIntervalSince(lastPowerRefresh) > 1 { refreshPower() }
            enqueue(event) // Show the connection immediately; battery owns its later countdown.
        }
        let now = Date()
        for index in pending.indices where pending[index].event.kind == .mouse
            && updated[pending[index].event.address]?.main != nil {
            pending[index].ready = now
        }
        deliverPending()
        // Refresh an already-visible mouse card in place; do not restart its
        // timeout, transition or token just because its battery query finished.
        if let active = BatteryStatusViewModel.shared.activeAccessoryConnection,
           active.kind == .mouse, !BatteryStatusViewModel.shared.isAccessoryConnectionPreview {
            if let current = updated[active.address] {
                BatteryStatusViewModel.shared.updateAccessoryConnectionBattery(current)
            } else { BatteryStatusViewModel.shared.dismissAccessoryConnection(address: active.address) }
        }
    }
    /// Polling must remain fast, but identical snapshots need no UI invalidation.
    /// A stable address tie-break also prevents equal-name devices swapping order.
    func updateConnectedMice(_ events: [AccessoryConnectionEvent]) {
        let snapshot = events.sorted {
            $0.name == $1.name ? $0.address < $1.address : $0.name < $1.name
        }
        guard snapshot != connectedMice else { return }
        connectedMice = snapshot
    }

    private func refreshPower() {
        guard !refreshingPower else { return }
        if AccessorySystemPowerSource.read() != nil {
            pollMice()
            return
        }
        refreshingPower = true
        worker.async { [weak self] in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "accps"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            var result: [String: [Int]] = [:]
            do {
                try process.run()
                // Bound a slow system query; never wait/spin the main run loop.
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
                if process.terminationStatus == 0 { result = AccessoryPowerReadings.parse(data) }
            } catch { }
            let readings = result
            Task { @MainActor in
                guard let self else { return }
                self.refreshingPower = false; self.lastPowerRefresh = Date(); self.powerReadings = readings
                if self.awake && Defaults[.showMouseConnections] {
                    self.pollMice()
                    let now = Date()
                    for index in self.pending.indices where self.pending[index].event.kind == .mouse
                        && self.mice[self.pending[index].event.address]?.main != nil {
                        self.pending[index].ready = now
                    }
                    self.deliverPending()
                }
            }
        }
    }
    private func deliverPending() {
        let now = Date()
        pending.removeAll { $0.expires < now || !enabled($0.event) }
        let coordinator = DynamicIslandViewCoordinator.shared
        guard awake, Defaults[.enableSystemHUD], (NSApp.delegate as? AppDelegate)?.vm.notchState != .open,
              (!coordinator.sneakPeek.show || [.music, .desktop].contains(coordinator.sneakPeek.type)),
              (!coordinator.expandingView.show || [.music, .timer, .recording].contains(coordinator.expandingView.type)),
              let index = pending.firstIndex(where: { $0.ready <= now }) else { return }
        var event = pending.remove(at: index).event
        if event.kind == .airPods && event.connected {
            guard BluetoothAudioManager.shared.connectedDevices.contains(where: { $0.address == event.address }) else { return }
            event = event.updating(BluetoothAudioManager.shared.airPodsBatteryReadings().first { $0.address == event.address })
        } else if event.kind == .mouse {
            guard let current = mice[event.address] else { return }; event = current
        }
        let style = event.kind == .mouse ? Defaults[.mouseConnectionStyle]
            : event.connected ? Defaults[.airPodsConnectionStyle] : Defaults[.airPodsDisconnectionStyle]
        let duration = event.kind == .mouse ? Defaults[.mouseConnectionDuration] : Defaults[.airPodsConnectionDuration]
        HUDSuppressionCoordinator.shared.suppressVolumeHUD(for: TimeInterval(duration))
        BatteryStatusViewModel.shared.presentAccessoryConnection(event, style: style, duration: duration)
    }
    private func enabled(_ event: AccessoryConnectionEvent) -> Bool {
        event.kind == .mouse ? Defaults[.showMouseConnections]
            : Defaults[.showBluetoothDeviceConnections] && (event.connected || Defaults[.showAirPodsDisconnections])
    }
    func preview(kind: AccessoryKind, connected: Bool, style: BatteryNotificationStyle) {
        rememberAirPods()
        let source = kind == .mouse ? connectedMice.first ?? .mousePreview : knownAirPods.values.first ?? .airPodsPreview
        let event = AccessoryConnectionEvent(address: source.address, name: source.name, symbol: source.symbol,
            kind: kind, connected: connected, left: source.left, right: source.right, main: source.main, artworkModel: source.artworkModel)
        BatteryStatusViewModel.shared.presentAccessoryConnection(event, style: style,
            duration: kind == .mouse ? Defaults[.mouseConnectionDuration] : Defaults[.airPodsConnectionDuration], preview: true)
    }
}
