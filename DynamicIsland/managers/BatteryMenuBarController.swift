import AppKit
import SwiftUI
import Combine
import Defaults
import Darwin

/// A separate, coloured status item. The existing notch icon/menu are untouched.
@MainActor
final class BatteryMenuBarController: NSObject, NSPopoverDelegate {
    static let shared = BatteryMenuBarController()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private let model = BatteryMenuModel()
    private var started = false

    func start() {
        guard !started else { return }; started = true
        popover.behavior = .transient
        popover.delegate = self
        Defaults.publisher(.batteryMenuBarEnabled).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configure() }.store(in: &subscriptions)
        for key in [Defaults.Keys.batteryMenuBarColor, Defaults.Keys.batteryMenuBarPercentage] {
            Defaults.publisher(key).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateIcon() }.store(in: &subscriptions)
        }
        BatteryStatusViewModel.shared.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &subscriptions)
        configure()
    }
    private func configure() {
        guard Defaults[.batteryMenuBarEnabled] else {
            popover.performClose(nil)
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil; return
        }
        if item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status.button?.target = self
            status.button?.action = #selector(toggle)
            status.button?.setAccessibilityLabel("Orbit Battery")
            item = status
        }
        updateIcon()
    }
    private func updateIcon() {
        guard let button = item?.button else { return }
        let b = BatteryStatusViewModel.shared
        let level = b.isInitial ? nil : min(100, max(0, Int(b.levelBattery.rounded())))
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.image = BatteryMenuIcon.image(level: level, charging: b.isCharging,
                lowPower: b.isInLowPowerMode, color: Defaults[.batteryMenuBarColor],
                percentage: Defaults[.batteryMenuBarPercentage])
        }
        button.toolTip = "Orbit · " + (level.map { "\($0)%" } ?? "Battery")
            + (b.isCharging ? " · Charging" : b.isPluggedIn ? " · Power connected" : " · On battery")
    }
    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        let screenHeight = button.window?.screen?.visibleFrame.height ?? 800
        let height = min(700, max(360, screenHeight - 48))
        let host = NSHostingController(rootView: BatteryMenuContent(model: model))
        host.sizingOptions = []
        host.view.frame = NSRect(x: 0, y: 0, width: 396, height: height)
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 396, height: height)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        model.begin()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func popoverDidClose(_ notification: Notification) {
        refreshTask?.cancel(); refreshTask = nil
        model.end()
        // Release hidden SwiftUI subscriptions, charts and animation timelines.
        popover.contentViewController = nil
    }
}

@MainActor
final class BatteryMenuModel: ObservableObject {
    @Published var snapshot = BatteryMenuSnapshot()
    private let worker = DispatchQueue(label: "com.kayhsen.NotchFlow.battery-menu", qos: .utility)
    private var visible = false
    private var reading = false
    private var generation = 0
    private let viewerToken = UUID()
    private var baseline: [Int32: (energy: UInt64, start: UInt64, date: Date)] = [:]
    func begin() {
        visible = true; generation += 1; baseline.removeAll()
        BatteryHistoryManager.shared.setVisible(true, token: viewerToken)
    }
    func end() {
        visible = false; generation += 1; baseline.removeAll()
        BatteryHistoryManager.shared.setVisible(false, token: viewerToken)
    }
    func refresh() {
        guard visible, !reading else { return }
        reading = true
        let token = generation
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0.localizedName ?? "App") }
        worker.async { [weak self] in
            let power = BatteryMenuSnapshot.read()
            var energy: [(Int32, String, UInt64, UInt64)] = []
            for (pid, name) in apps {
                var usage = rusage_info_v6()
                let result = withUnsafeMutablePointer(to: &usage) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                    }
                }
                if result == 0 { energy.append((pid, name, usage.ri_energy_nj, usage.ri_proc_start_abstime)) }
            }
            Task { @MainActor in
                guard let self else { return }; self.reading = false
                guard self.visible, self.generation == token else { return }
                var value = power
                let battery = BatteryStatusViewModel.shared
                value.level = power.level
                value.lowPower = battery.isInLowPowerMode
                if battery.isCharging, battery.timeToFullCharge > 0 {
                    value.eta = MacBatteryManager.format(minutes: battery.timeToFullCharge) + " until full"
                } else if !battery.isPluggedIn, battery.timeToEmpty > 0 {
                    value.eta = "About " + MacBatteryManager.format(minutes: battery.timeToEmpty) + " remaining"
                }
                let history = BatteryHistoryManager.shared
                value.health = history.health?.maximumCapacityPercent ?? value.health
                value.condition = history.health?.condition
                let recent = history.samples.filter { $0.date > Date().addingTimeInterval(-86400) }
                let step = max(1, recent.count / 120)
                value.history = stride(from: 0, to: recent.count, by: step).map { BatteryMenuPoint(date: recent[$0].date, level: recent[$0].level) }
                if let last = recent.last, value.history.last?.date != last.date {
                    value.history.append(BatteryMenuPoint(date: last.date, level: last.level))
                }
                let pods = AirPodsBatteryWarningManager.shared.readings
                value.devices = pods.map { BatteryMenuDevice(id: $0.address, name: $0.name, symbol: $0.symbol,
                    detail: $0.detail, level: [$0.left, $0.right, $0.main].compactMap { $0 }.min()) }
                let podAddresses = Set(pods.map(\.address))
                value.devices += BluetoothAudioManager.shared.connectedDevices.filter { !podAddresses.contains($0.address) }
                    .map { BatteryMenuDevice(id: $0.address, name: $0.name, symbol: "headphones", detail: $0.batteryLevel.map { "\($0)%" } ?? "Battery unavailable", level: $0.batteryLevel) }
                value.devices += AccessoryConnectionManager.shared.connectedMice.map {
                    BatteryMenuDevice(id: $0.address, name: $0.name, symbol: $0.symbol, detail: $0.detail, level: $0.main)
                }
                value.devices += OrbitBatteryHub.shared.devices.filter { OrbitDeviceReconciler.isPhoneInventoryID($0.id) && $0.connected && $0.usableLevel(at: Date()) != nil }
                    .map { BatteryMenuDevice(id: $0.id, name: $0.name, symbol: $0.symbol,
                        detail: $0.charging ? "Charging" : $0.detail, level: $0.level) }
                value.devices = OrbitDeviceReconciler.menuRows(value.devices,
                    combine: Defaults[.orbitCombineDuplicateDevices], at: Date())
                value.devices.sort { ($0.level ?? 101) < ($1.level ?? 101) }
                let now = Date()
                var next: [Int32: (energy: UInt64, start: UInt64, date: Date)] = [:]
                for (pid, name, joules, start) in energy {
                    next[pid] = (joules, start, now)
                    if let old = self.baseline[pid], old.start == start, joules >= old.energy {
                        let seconds = now.timeIntervalSince(old.date)
                        let watts = seconds > 0 ? Double(joules - old.energy) / 1_000_000_000 / seconds : 0
                        if watts >= 0.01, watts <= 200 { value.appEnergy.append(.init(pid: pid, name: name, watts: watts)) }
                    }
                }
                self.baseline = next
                value.appEnergy = Array(value.appEnergy.sorted { $0.watts > $1.watts }.prefix(5))
                if self.snapshot != value { self.snapshot = value }
            }
        }
    }
}
