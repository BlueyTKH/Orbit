import AppKit
import Combine
import Defaults
import ApplicationServices
import os

@MainActor
final class AirPodsBatteryWarningManager: ObservableObject {
    static let shared = AirPodsBatteryWarningManager()
    @Published private(set) var readings: [AirPodsBatteryReading] = []
    @Published private(set) var connectedAirPods: [BluetoothAudioDevice] = []
    @Published private(set) var nativeReplacementCount = 0
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var nativeTimer: Timer?
    private var settleUntil: [String: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var lastNativePresentation: [String: Date] = [:]
    private var nativeReadings: [String: AirPodsBatteryReading] = [:]
    private var reportedAddresses = Set<String>()
    private var pendingNativeAddresses = Set<String>()
    private var started = false
    private var sessionActive = true
    private var tracker = AirPodsBatteryWarningTracker(delivered: Set(Defaults[.deliveredAirPodsBatteryWarnings]))
    private let sound = AudioPlayer()
    private let native = AirPodsSystemAlertReplacement()
    private let bluetooth = BluetoothAudioManager.shared
    private let coordinator = DynamicIslandViewCoordinator.shared
    private var warnings: [LowBatteryWarning] { AirPodsWarningConfiguration.normalized(Defaults[.airPodsBatteryWarnings]) }
    private var threshold: Int { warnings.map(\.percentage).max() ?? 20 }

    func start() {
        guard !started else { return }
        started = true
        if UserDefaults.standard.object(forKey: "airPodsBatteryWarnings") == nil {
            Defaults[.airPodsBatteryWarnings] = AirPodsWarningConfiguration.initial(
                threshold: Defaults[.airPodsBatteryWarningThreshold], duration: Defaults[.airPodsBatteryWarningDuration],
                style: Defaults[.airPodsBatteryWarningStyle], sound: Defaults[.airPodsBatteryWarningSound])
        }
        native.onMatch = { [weak self] reading, completion in
            Task { @MainActor in
                guard let self, self.monitoring, Defaults[.enableSystemHUD], Defaults[.replaceSystemAirPodsBatteryWarnings],
                      self.connectedAirPods.contains(where: { $0.address == reading.address }),
                      reading.isFresh(at: Date()), reading.listeningLevel != nil else { completion(false); return }
                let current = reading
                self.nativeReadings[current.address] = current
                // A native warning below a custom threshold still gets our selected UI.
                // Subsequent native repeats for this charge cycle are dismissed quietly.
                guard let warning = self.warnings.first(where: { (current.listeningLevel ?? 101) <= $0.percentage }) else {
                    completion(false); return
                }
                let delivered = self.tracker.delivered.contains(AirPodsBatteryWarningTracker.key(address: current.address, threshold: warning.percentage))
                let measured = self.reportedAddresses.contains(current.address)
                switch AirPodsNativeWarningReplayPolicy.action(delivered: delivered, hasMeasuredReading: measured,
                    lastPresentation: self.lastNativePresentation[current.address], canPresent: self.canPresent, now: Date()) {
                case .queueAndDismiss:
                    self.pendingNativeAddresses.insert(current.address)
                    self.readings.removeAll { $0.address == current.address }
                    self.readings.append(current)
                    self.scheduleEvaluation()
                    completion(true)
                case .dismissDuplicate: completion(true)
                case .presentAndDismiss:
                    guard self.present(current, warning: warning) else { completion(false); return }
                    self.lastNativePresentation[current.address] = Date()
                    if measured { self.markDelivered(current) }
                    completion(true)
                }
            }
        }
        native.onDismiss = { [weak self] in
            Task { @MainActor in self?.nativeReplacementCount += 1 }
        }
        bluetooth.$connectedDevices.receive(on: DispatchQueue.main).sink { [weak self] devices in
            Task { @MainActor in self?.connectionsChanged(devices) }
        }.store(in: &subscriptions)
        for key in [Defaults.Keys.airPodsBatteryWarningsEnabled, .replaceSystemAirPodsBatteryWarnings, .enableSystemHUD] {
            Defaults.publisher(key, options: []).sink { [weak self] _ in
                Task { @MainActor in self?.configureMonitoring() }
            }.store(in: &subscriptions)
        }
        Defaults.publisher(.airPodsBatteryWarnings, options: []).sink { [weak self] _ in
            Task { @MainActor in self?.configureMonitoring() }
        }.store(in: &subscriptions)
        LockScreenManager.shared.$isLocked.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.configureMonitoring() }
        }.store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.sessionActive = false; self?.configureMonitoring() }
            }.store(in: &subscriptions)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.sessionActive = true; self?.configureMonitoring() }
            }.store(in: &subscriptions)
        }
        workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification).sink { [weak self] _ in
            Task { @MainActor in self?.updateNativeMonitoring() }
        }.store(in: &subscriptions)
        coordinator.$expandingView.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleEvaluation() }
        }.store(in: &subscriptions)
        coordinator.$sneakPeek.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleEvaluation() }
        }.store(in: &subscriptions)
        configureMonitoring()
    }

    private var monitoring: Bool {
        sessionActive && !LockScreenManager.shared.isLocked
            && Defaults[.airPodsBatteryWarningsEnabled] && !warnings.isEmpty && !connectedAirPods.isEmpty
    }
    private var canPresent: Bool {
        guard monitoring, Defaults[.enableSystemHUD], !NSScreen.screens.isEmpty else { return false }
        if let delegate = NSApp.delegate as? AppDelegate, delegate.vm.notchState != .closed { return false }
        if coordinator.sneakPeek.show && ![SneakContentType.music, .desktop].contains(coordinator.sneakPeek.type) { return false }
        if coordinator.expandingView.show {
            if coordinator.expandingView.type == .battery {
                return BatteryStatusViewModel.shared.activeAirPodsBatteryWarning != nil
            }
            return [.music, .timer, .recording].contains(coordinator.expandingView.type)
        }
        return true
    }

    private func connectionsChanged(_ devices: [BluetoothAudioDevice]) {
        let now = Date()
        let airPods = devices.filter { $0.deviceType.isAirPods }
        let old = Set(connectedAirPods.map(\.address))
        let new = Set(airPods.map(\.address))
        for address in new.subtracting(old) { settleUntil[address] = now.addingTimeInterval(2) }
        settleUntil = settleUntil.filter { new.contains($0.key) }
        nativeReadings = nativeReadings.filter { new.contains($0.key) }
        pendingNativeAddresses.formIntersection(new)
        connectedAirPods = airPods
        readings.removeAll { !new.contains($0.address) }
        if new != old { configureMonitoring() }
        else if monitoring { sample() }
    }

    private func configureMonitoring() {
        refreshTimer?.invalidate(); refreshTimer = nil
        nativeTimer?.invalidate(); nativeTimer = nil
        refreshTask?.cancel()
        if monitoring {
            refresh()
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common); refreshTimer = timer
        } else {
            native.setReadings([])
            pendingNativeAddresses.removeAll()
            BatteryStatusViewModel.shared.dismissAirPodsBatteryWarning()
        }
    }

    private func refresh() {
        guard monitoring else { return }
        bluetooth.refreshConnectedDeviceBatteries() // Reuses its off-main cached profiler refresh.
        sample()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.1))
            guard !Task.isCancelled else { return }
            self?.sample()
        }
    }

    private func sample() {
        guard monitoring else { return }
        let now = Date()
        var sampled = bluetooth.airPodsBatteryReadings(now: now)
        reportedAddresses = Set(sampled.map(\.address))
        for native in nativeReadings.values where native.isFresh(at: now) {
            if let index = sampled.firstIndex(where: { $0.address == native.address }) {
                let sample = sampled[index]
                let charging = sample.leftCharging || sample.rightCharging || sample.mainCharging
                if sample.observedAt < native.observedAt
                    || (!charging && (sample.listeningLevel ?? 101) > (native.listeningLevel ?? 101)) {
                    sampled[index] = native
                }
            } else { sampled.append(native) }
        }
        readings = sampled
        evaluate()
        updateNativeMonitoring()
    }

    private func scheduleEvaluation() {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func evaluate() {
        let now = Date()
        let old = tracker.delivered
        for reading in readings {
            for warning in warnings { tracker.recover(reading, threshold: warning.percentage, now: now) }
        }
        if old != tracker.delivered { saveState() }
        guard canPresent else { return }
        let candidates = readings.filter { (settleUntil[$0.address] ?? .distantPast) <= now }
            .filter { reportedAddresses.contains($0.address) || pendingNativeAddresses.contains($0.address) }
            .filter { tracker.nextWarning($0, warnings: warnings, now: now) != nil }
            .sorted { ($0.listeningLevel ?? 101) < ($1.listeningLevel ?? 101) }
        if let reading = candidates.first, let warning = tracker.nextWarning(reading, warnings: warnings, now: now),
           present(reading, warning: warning) { markDelivered(reading) }
    }

    private func present(_ reading: AirPodsBatteryReading, warning: LowBatteryWarning) -> Bool {
        guard reading.listeningLevel != nil, reading.isFresh(at: Date()), canPresent else { return false }
        BatteryStatusViewModel.shared.presentAirPodsBatteryWarning(reading,
            style: warning.presentation.style, duration: warning.duration)
        if warning.sound { sound.play(fileName: "lowbattery", fileExtension: "mp3") }
        return true
    }
    private func markDelivered(_ reading: AirPodsBatteryReading) {
        pendingNativeAddresses.remove(reading.address)
        tracker.markDelivered(reading, warnings: warnings, now: Date()); saveState()
    }
    private func saveState() { Defaults[.deliveredAirPodsBatteryWarnings] = tracker.delivered.sorted() }

    private func updateNativeMonitoring() {
        nativeTimer?.invalidate(); nativeTimer = nil
        guard monitoring, Defaults[.enableSystemHUD], Defaults[.replaceSystemAirPodsBatteryWarnings], AXIsProcessTrusted() else {
            native.setReadings([]); return
        }
        let now = Date()
        let context = connectedAirPods.map { device in
            readings.first(where: { $0.address == device.address && $0.isFresh(at: now) })
                ?? AirPodsBatteryReading(address: device.address, name: device.name, symbol: device.deviceType.sfSymbol,
                                         left: nil, right: nil, main: nil, observedAt: now)
        }
        native.setReadings(context, aliases: bluetooth.airPodsNativePopupNames())
        // AX events handle appearance immediately. Poll only while the buds are
        // low, as a fallback for menu-bar hosts that omit a window notification.
        if context.contains(where: { $0.listeningLevel == nil || ($0.listeningLevel ?? 101) <= max(threshold, 20) }) {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.native.requestScan() }
            }
            RunLoop.main.add(timer, forMode: .common); nativeTimer = timer
        }
    }

    func preview(warning: LowBatteryWarning) {
        let threshold = warning.percentage
        let style = warning.presentation.style
        let reading = (readings.first ?? .preview).previewing(level: threshold)
        BatteryStatusViewModel.shared.presentAirPodsBatteryWarning(reading, style: style,
            duration: warning.duration, preview: true)
    }
}

/// Uses only advertised dismiss/close/cancel actions on a verified native popup.
/// No global Sound setting changes, process termination or focus/keyboard input.
final class AirPodsSystemAlertReplacement: @unchecked Sendable {
    var onMatch: ((AirPodsBatteryReading, @escaping (Bool) -> Void) -> Void)?
    var onDismiss: (() -> Void)?
    private let worker = DispatchQueue(label: "com.kayhsen.NotchFlow.airpods.native-alert", qos: .utility)
    private let lock = NSLock()
    private var readings: [AirPodsBatteryReading] = []
    private var aliases: [String: [String]] = [:]
    private let logger = os.Logger(subsystem: "com.kayhsen.NotchFlow", category: "airpods-native")
    private var lastStatus = ""
    private func status(_ message: String) {
        guard message != lastStatus else { return }; lastStatus = message
        logger.notice("\(message, privacy: .public)")
    }
    private var apps: [(pid_t, String)] = []
    private var queued = false
    private var macEnabled = false
    private var observers: [pid_t: AXObserver] = [:] // Worker-owned.

    @MainActor func setReadings(_ readings: [AirPodsBatteryReading], aliases: [String: [String]] = [:], macEnabled: Bool = false) {
        let apps = readings.isEmpty && !macEnabled ? [] : NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
            guard let owner = app.bundleIdentifier, (AirPodsNativeLowBatteryMatcher.owners.contains(owner) || (macEnabled && MacNativeBatteryAlertMatcher.owners.contains(owner))) else { return nil }
            return (app.processIdentifier, owner)
        }
        lock.lock(); self.macEnabled = macEnabled; self.readings = readings; self.aliases = aliases; self.apps = apps; lock.unlock()
        worker.async { [weak self] in self?.reconcile(apps) }
        requestScan()
    }

    private func reconcile(_ apps: [(pid_t, String)]) {
        let pids = Set(apps.map { $0.0 })
        for pid in Array(observers.keys) where !pids.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        for (pid, _) in apps where observers[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                Unmanaged<AirPodsSystemAlertReplacement>.fromOpaque(context).takeUnretainedValue().appearanceChanged()
            }, &observer) == .success, let observer else { continue }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            for notification in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXFocusedWindowChangedNotification, kAXLayoutChangedNotification] {
                _ = AXObserverAddNotification(observer, app, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            logger.notice("Native AirPods observer attached to \(pid, privacy: .public)")
            observers[pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private func appearanceChanged() {
        requestScan()
        // Some hosts announce the window before its labels/actions are populated.
        for delay in [0.3, 0.8] {
            worker.asyncAfter(deadline: .now() + delay) { [weak self] in self?.requestScan() }
        }
    }
    func requestScan() {
        lock.lock()
        guard !queued, (!readings.isEmpty || macEnabled) else { lock.unlock(); return }
        queued = true
        lock.unlock()
        worker.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let readings = self.readings; let aliases = self.aliases; let apps = self.apps; self.lock.unlock()
            self.scan(apps: apps, readings: readings, aliases: aliases)
            self.lock.lock(); self.queued = false; self.lock.unlock()
        }
    }

    private func scan(apps: [(pid_t, String)], readings: [AirPodsBatteryReading], aliases: [String: [String]]) {
        lock.lock(); let macEnabled = self.macEnabled; lock.unlock()
        guard !readings.isEmpty || macEnabled else { return }
        let deadline = Date().addingTimeInterval(1)
        let cc = Bundle(path: "/System/Library/CoreServices/ControlCenter.app")
        let bt = Bundle(path: "/System/Library/CoreServices/BluetoothUIService.app")
        let labels = ["Low Battery", cc?.localizedString(forKey: "HEADPHONES_LOW_BATTERY", value: "Low Battery", table: "Sound"),
                      bt?.localizedString(forKey: "LOW_BATTERY", value: "Low Battery", table: "Localizable")].compactMap { $0 }
        let excludedLabels = ["Case Low Battery", cc?.localizedString(forKey: "CASE_LOW_BATTERY", value: "Case Low Battery", table: "Sound")].compactMap { $0 }
        for (pid, owner) in apps where Date() < deadline {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            var rawWindows: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows)
            var windows = rawWindows as? [AXUIElement] ?? []
            if result != .success { status("Native popup window query failed: \(result.rawValue)") }
            // Borderless system banners may appear as a popover/direct child
            // rather than in AXWindows. Only inspect window/popover roots.
            let children: [AXUIElement] = attribute(app, kAXChildrenAttribute) ?? []
            for child in children where Date() < deadline {
                let role: String? = attribute(child, kAXRoleAttribute)
                if [kAXWindowRole, kAXPopoverRole, kAXSheetRole].contains(role ?? ""), !windows.contains(where: { CFEqual($0, child) }) {
                    windows.append(child)
                }
            }
            if let focused: AXUIElement = attribute(app, kAXFocusedWindowAttribute), !windows.contains(where: { CFEqual($0, focused) }) {
                windows.append(focused)
            }
            for window in windows where Date() < deadline {
                guard let sizeValue: AXValue = attribute(window, kAXSizeAttribute) else { continue }
                var size = CGSize.zero
                guard AXValueGetValue(sizeValue, .cgSize, &size), (28...190).contains(size.height) else { continue }
                let nodes = descendants(window, deadline: deadline)
                let texts = textValues(nodes, deadline: deadline)
                if macEnabled && MacNativeBatteryAlertMatcher.matches(owner: owner, texts: texts, width: size.width, height: size.height) {
                    // Re-read immediately; never close a reused banner on stale text.
                    lock.lock(); let allowed = self.macEnabled; lock.unlock()
                    let currentNodes = descendants(window, deadline: deadline)
                    if allowed && MacNativeBatteryAlertMatcher.matches(owner: owner, texts: textValues(currentNodes, deadline: deadline), width: size.width, height: size.height) {
                        status(dismiss(window, nodes: currentNodes) ? "Native Mac battery alert dismissed" : "Mac battery alert has no successful dismissal action")
                    }
                    continue
                }
                guard let matched = AirPodsNativeLowBatteryMatcher.match(owner: owner, texts: texts,
                    width: size.width, height: size.height, readings: readings, labels: labels, aliases: aliases,
                    excludedLabels: excludedLabels, now: Date()),
                    let reading = AirPodsNativeLowBatteryMatcher.readingFromPopup(matched, texts: texts, now: Date()) else { continue }
                status("Matched AirPods low-battery popup in \(owner)")
                let callback = onMatch
                DispatchQueue.main.async {
                    callback?(reading) { [weak self] allowed in
                        guard allowed, let self else { return }
                        self.worker.async {
                            self.lock.lock(); let currentReadings = self.readings; let currentAliases = self.aliases; self.lock.unlock()
                            guard currentReadings.contains(where: { $0.address == reading.address && $0.isFresh(at: Date()) }) else { return }
                            // The host may reuse a popup window for a different event.
                            // Revalidate immediately before performing any dismiss action.
                            let deadline = Date().addingTimeInterval(1)
                            let nodes = self.descendants(window, deadline: deadline)
                            let texts = self.textValues(nodes, deadline: deadline)
                            guard let currentSizeValue: AXValue = self.attribute(window, kAXSizeAttribute) else { return }
                            var currentSize = CGSize.zero
                            guard AXValueGetValue(currentSizeValue, .cgSize, &currentSize) else { return }
                            guard AirPodsNativeLowBatteryMatcher.match(owner: owner, texts: texts,
                                width: currentSize.width, height: currentSize.height, readings: currentReadings, labels: labels, aliases: currentAliases,
                                excludedLabels: excludedLabels, now: Date()) != nil else { return }
                            if self.dismiss(window, nodes: nodes) {
                                self.status("Native AirPods popup accepted a dismiss action")
                                DispatchQueue.main.async { self.onDismiss?() }
                            } else { self.status("Matched AirPods popup exposes no successful dismissal action") }
                        }
                    }
                }
            }
        }
    }

    private func descendants(_ root: AXUIElement, deadline: Date) -> [AXUIElement] {
        var nodes = [root]; var index = 0
        while index < nodes.count && nodes.count < 100 && Date() < deadline {
            let children: [AXUIElement] = attribute(nodes[index], kAXChildrenAttribute) ?? []
            nodes.append(contentsOf: children.prefix(100 - nodes.count)); index += 1
        }
        return nodes
    }
    private func attribute<T>(_ node: AXUIElement, _ name: String) -> T? {
        AXUIElementSetMessagingTimeout(node, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
    private func textValues(_ nodes: [AXUIElement], deadline: Date) -> [String] {
        var values: [String] = []
        for node in nodes where Date() < deadline {
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let text: String = attribute(node, name) { values.append(text) }
                else if name == kAXValueAttribute, let number: NSNumber = attribute(node, name) {
                    let role: String? = attribute(node, kAXRoleAttribute)
                    if role == kAXStaticTextRole, let level = AirPodsBatteryReading.percentage(number) {
                        values.append("\(level)")
                    } else if role == kAXProgressIndicatorRole {
                        let maximum: NSNumber? = attribute(node, kAXMaxValueAttribute)
                        let value = maximum?.doubleValue == 1 ? number.doubleValue * 100 : number.doubleValue
                        if let level = AirPodsBatteryReading.percentage(NSNumber(value: value.rounded())) { values.append("\(level)") }
                    }
                }
            }
        }
        return values
    }
    private func dismiss(_ window: AXUIElement, nodes: [AXUIElement]) -> Bool {
        for buttonAttribute in [kAXCloseButtonAttribute, kAXCancelButtonAttribute] {
            if let button: AXUIElement = attribute(window, buttonAttribute),
               AXUIElementPerformAction(button, kAXPressAction as CFString) == .success { return true }
        }
        if AXUIElementPerformAction(window, kAXCancelAction as CFString) == .success { return true }
        var expandedSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(window, kAXExpandedAttribute as CFString, &expandedSettable) == .success,
           expandedSettable.boolValue,
           AXUIElementSetAttributeValue(window, kAXExpandedAttribute as CFString, kCFBooleanFalse) == .success { return true }
        let deadline = Date().addingTimeInterval(1)
        for node in nodes where Date() < deadline {
            var names: CFArray?
            guard AXUIElementCopyActionNames(node, &names) == .success else { continue }
            let actions = names as? [String] ?? []
            for action in [kAXCancelAction, "AXDismiss"] where actions.contains(action) {
                if AXUIElementPerformAction(node, action as CFString) == .success { return true }
            }
            let role: String? = attribute(node, kAXRoleAttribute)
            let title: String = attribute(node, kAXTitleAttribute) ?? attribute(node, kAXDescriptionAttribute) ?? ""
            if role == kAXButtonRole, ["dismiss", "close"].contains(title.lowercased()),
               actions.contains(kAXPressAction), AXUIElementPerformAction(node, kAXPressAction as CFString) == .success { return true }
        }
        return false
    }
}
