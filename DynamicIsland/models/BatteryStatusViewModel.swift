/*
 * NotchFlow (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import Cocoa
import Defaults
import Foundation
import IOKit.ps
import SwiftUI

enum BatteryTemporaryHUDKind: Equatable {
    case charging
    case lowBattery
    case fullBattery
    case lowPowerEnabled
    case lowPowerDisabled
    case unplugged
}

extension Notification.Name {
    static let notchflowPrepareBatteryPreview = Notification.Name("NotchFlow.prepareBatteryPreview")
}

enum BatteryPreviewLayout {
    static func canvas(surface: CGSize, opened: CGSize) -> CGSize {
        CGSize(width: max(surface.width, opened.width), height: max(surface.height, opened.height))
    }
}

/// The card, SwiftUI canvas and AppKit window must reserve the same surface.
/// Keeping separate widths clipped the rounded ends of real full/low alerts.
enum BatteryTemporaryHUDLayout {
    static func surface(kind: BatteryTemporaryHUDKind, style: BatteryNotificationStyle, closed: CGSize) -> CGSize {
        switch (kind, style) {
        case (_, .compact):
            return CGSize(width: closed.width + 180, height: closed.height)
        case (.lowBattery, .standard):
            return CGSize(width: closed.width + 150, height: closed.height + 75)
        case (.fullBattery, .standard):
            return CGSize(width: closed.width + 140, height: closed.height + 70)
        case (.charging, .standard), (.lowPowerEnabled, .standard), (.lowPowerDisabled, .standard), (.unplugged, .standard):
            return CGSize(width: closed.width + 190, height: closed.height + 70)
        }
    }
}

enum BatteryTemporaryHUDPresentation {
    static func style(for kind: BatteryTemporaryHUDKind, lowWarningOverride: BatteryNotificationStyle?,
                      lowDefault: BatteryNotificationStyle, fullDefault: BatteryNotificationStyle,
                      powerStyle: BatteryNotificationStyle? = nil) -> BatteryNotificationStyle {
        switch kind {
        case .charging: return powerStyle ?? Defaults[.chargingBatteryHUDStyle]
        case .lowBattery: return lowWarningOverride ?? lowDefault
        case .fullBattery: return fullDefault
        case .lowPowerEnabled: return powerStyle ?? Defaults[.lowPowerEnabledBatteryHUDStyle]
        case .lowPowerDisabled: return powerStyle ?? Defaults[.lowPowerDisabledBatteryHUDStyle]
        case .unplugged: return powerStyle ?? Defaults[.unpluggedBatteryHUDStyle]
        }
    }
}

/// A view model that manages and monitors the battery status of the device
class BatteryStatusViewModel: ObservableObject {

    private var wasCharging: Bool = false
    private var powerSourceChangedCallback: IOPowerSourceCallbackType?
    private var runLoopSource: Unmanaged<CFRunLoopSource>?
    var animations: DynamicIslandAnimations = DynamicIslandAnimations()
    private let lowBatteryAlertSoundPlayer = AudioPlayer()
    private var lowBatteryWarningTracker = LowBatteryWarningTracker()

    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared

    @Published private(set) var levelBattery: Float = 0.0
    @Published private(set) var maxCapacity: Float = 0.0
    @Published private(set) var isPluggedIn: Bool = false
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isInLowPowerMode: Bool = false
    @Published private(set) var isInitial: Bool = false
    @Published private(set) var timeToFullCharge: Int = 0
    @Published private(set) var timeToEmpty: Int = 0
    @Published private(set) var statusText: String = ""
    @Published private(set) var activeTemporaryHUDKind: BatteryTemporaryHUDKind?
    @Published private(set) var activeTemporaryHUDToken: UUID = UUID()
    @Published private(set) var activeTemporaryHUDTargetScreenName: String?
    @Published private(set) var activeTemporaryHUDLevelOverride: Int?
    @Published private(set) var activeTemporaryHUDLowPowerModeOverride: Bool?

    @Published private(set) var activeTemporaryHUDStyleOverride: BatteryNotificationStyle?
    @Published private(set) var activeTemporaryHUDIsCritical = false
    @Published private(set) var activeAccessoryConnection: AccessoryConnectionEvent?
    var hasAccessoryHUD: Bool { activeAirPodsBatteryWarning != nil || activeAccessoryConnection != nil }
    @Published private(set) var activeAirPodsBatteryWarning: AirPodsBatteryReading?
    @Published private(set) var previewCanvasActive = false
    private var previewCanvasCleanup: Task<Void, Never>?
    private(set) var isAccessoryConnectionPreview = false
    private var mouseBatteryClock: MouseBatteryPresentationClock?
    private var mouseBatteryFallback: Task<Void, Never>?

    private let managerBattery = BatteryActivityManager.shared
    private var managerBatteryId: Int?

    static let shared = BatteryStatusViewModel()

    /// Initializes the view model with a given BoringViewModel instance
    /// - Parameter vm: The BoringViewModel instance
    private init() {
        if UserDefaults.standard.object(forKey: "lowBatteryWarnings") == nil {
            Defaults[.lowBatteryWarnings] = LowBatteryWarning.initialWarnings(
                legacyThreshold: UserDefaults.standard.object(forKey: "lowBatteryHUDThreshold") as? Int,
                legacyDuration: Defaults[.lowBatteryHUDDuration], legacyStyle: Defaults[.lowBatteryHUDStyle])
        }
        lowBatteryWarningTracker = LowBatteryWarningTracker(delivered: Set(Defaults[.deliveredLowBatteryWarnings]))
        setupPowerStatus()
        lowBatteryWarningTracker.resetRecoveredWarnings(at: levelBattery)
        saveLowBatteryWarningState()
        setupMonitor()
    }

    /// Sets up the initial power status by fetching battery information
    private func setupPowerStatus() {
        let batteryInfo = managerBattery.initializeBatteryInfo()
        updateBatteryInfo(batteryInfo)
    }

    /// Sets up the monitor to observe battery events
    private func setupMonitor() {
        managerBatteryId = managerBattery.addObserver { [weak self] event in
            guard let self = self else { return }
            self.handleBatteryEvent(event)
        }
    }

    /// Handles battery events and updates the corresponding properties
    /// - Parameter event: The battery event to handle
    private func handleBatteryEvent(_ event: BatteryActivityManager.BatteryEvent) {
        switch event {
        case .powerSourceChanged(let isPluggedIn):
            print("🔌 Power source: \(isPluggedIn ? "Connected" : "Disconnected")")
            let wasPluggedIn = self.isPluggedIn
            withAnimation {
                self.isPluggedIn = isPluggedIn
                self.statusText = isPluggedIn ? String(localized: "Plugged In") : String(localized: "Unplugged")
            }
            if isPluggedIn { CriticalBatteryBorderManager.shared.dismiss() }
            if !wasPluggedIn && isPluggedIn {
                presentTemporaryBatteryHUDIfNeeded(kind: .charging)
            } else if wasPluggedIn && !isPluggedIn {
                presentTemporaryBatteryHUDIfNeeded(kind: .unplugged)
            }

        case .batteryLevelChanged(let level):
            print("🔋 Battery level: \(Int(level))%")
            let previousLevel = self.levelBattery
            withAnimation {
                self.levelBattery = level
            }
            self.handleLowBatteryAlertIfNeeded(previousLevel: previousLevel, newLevel: level)
            self.handleFullBatteryAlertIfNeeded(previousLevel: previousLevel, newLevel: level)

        case .lowPowerModeChanged(let isEnabled):
            print("⚡ Low power mode: \(isEnabled ? "Enabled" : "Disabled")")
            let wasEnabled = self.isInLowPowerMode
            withAnimation {
                self.isInLowPowerMode = isEnabled
                self.statusText = String(localized: "Low Power: \(self.isInLowPowerMode ? String(localized: "On") : String(localized: "Off"))")
            }
            if !wasEnabled && isEnabled {
                presentTemporaryBatteryHUDIfNeeded(kind: .lowPowerEnabled)
            } else if wasEnabled && !isEnabled {
                presentTemporaryBatteryHUDIfNeeded(kind: .lowPowerDisabled)
            }

        case .isChargingChanged(let isCharging):
            print("🔌 Charging: \(isCharging ? "Yes" : "No")")
            print("maxCapacity: \(self.maxCapacity)")
            print("levelBattery: \(self.levelBattery)")
            withAnimation {
                self.isCharging = isCharging
                self.statusText =
                    isCharging
                    ? String(localized: "Charging battery")
                    : (self.levelBattery < self.maxCapacity ? String(localized: "Not charging") : String(localized: "Full charge"))
            }

        case .timeToFullChargeChanged(let time):
            print("🕒 Time to full charge: \(time) minutes")
            withAnimation {
                self.timeToFullCharge = time
            }

        case .timeToEmptyChanged(let time):
            print("🕒 Time to empty: \(time) minutes")
            withAnimation {
                self.timeToEmpty = time
            }

        case .maxCapacityChanged(let capacity):
            print("🔋 Max capacity: \(capacity)")
            withAnimation {
                self.maxCapacity = capacity
            }

        case .error(let description):
            print("⚠️ Error: \(description)")
        }
    }

    /// Updates the battery information with the given BatteryInfo instance
    /// - Parameter batteryInfo: The BatteryInfo instance containing the battery data
    private func updateBatteryInfo(_ batteryInfo: BatteryInfo) {
        withAnimation {
            self.levelBattery = batteryInfo.currentCapacity
            self.isPluggedIn = batteryInfo.isPluggedIn
            self.isCharging = batteryInfo.isCharging
            self.isInLowPowerMode = batteryInfo.isInLowPowerMode
            self.timeToFullCharge = batteryInfo.timeToFullCharge
            self.timeToEmpty = batteryInfo.timeToEmpty
            self.maxCapacity = batteryInfo.maxCapacity
            self.statusText = batteryInfo.isPluggedIn ? String(localized: "Plugged In") : String(localized: "Unplugged")
        }
    }

    private func presentTemporaryBatteryHUDIfNeeded(kind: BatteryTemporaryHUDKind) {
        presentTemporaryBatteryHUDIfNeeded(kind: kind, force: false)
    }

    func triggerTestHUD(kind: BatteryTemporaryHUDKind) {
        if kind == .lowBattery {
            triggerTestLowBatteryWarning(Defaults[.lowBatteryWarnings].first(where: { $0.enabled }) ?? LowBatteryWarning.defaults[0])
            return
        }
        let previewLevel: Int

        switch kind {
        case .charging:
            previewLevel = max(12, min(95, Int(levelBattery.rounded())))
        case .lowBattery:
            previewLevel = max(5, min(20, Defaults[.lowBatteryHUDThreshold]))
        case .fullBattery:
            previewLevel = 100
        case .lowPowerEnabled, .lowPowerDisabled, .unplugged:
            previewLevel = max(12, min(95, Int(levelBattery.rounded())))
        }

        presentTemporaryBatteryHUDIfNeeded(
            kind: kind,
            force: true,
            levelOverride: previewLevel,
            lowPowerModeOverride: kind == .lowPowerEnabled ? true : (kind == .lowPowerDisabled ? false : nil)
        )
    }

    func triggerTestLowBatteryWarning(_ warning: LowBatteryWarning) {
        presentTemporaryBatteryHUDIfNeeded(kind: .lowBattery, force: true,
            levelOverride: warning.percentage, warning: warning)
    }

    @MainActor
    func presentAirPodsBatteryWarning(_ reading: AirPodsBatteryReading, style: BatteryNotificationStyle,
                                     duration: Int, preview: Bool = false) {
        guard let level = reading.listeningLevel else { return }
        let warning = LowBatteryWarning(percentage: level, duration: min(max(duration, 1), 60),
            presentation: style == .compact ? .compact : .expanded, sound: false)
        presentTemporaryBatteryHUDIfNeeded(kind: .lowBattery, force: preview,
            levelOverride: level, warning: warning, airPodsReading: reading)
    }

    @MainActor
    func dismissAirPodsBatteryWarning() {
        guard activeAirPodsBatteryWarning != nil,
              coordinator.expandingView.show, coordinator.expandingView.type == .battery else { return }
        coordinator.toggleExpandingView(status: false, type: .battery)
    }

    @MainActor
    func presentAccessoryConnection(_ event: AccessoryConnectionEvent, style: BatteryNotificationStyle,
                                    duration: Int, preview: Bool = false) {
        guard preview || Defaults[.enableSystemHUD] else { return }
        let presentation = LowBatteryWarning(percentage: 1, duration: min(max(duration, 1), 60),
            presentation: style == .compact ? .compact : .expanded, sound: false)
        presentTemporaryBatteryHUDIfNeeded(kind: .lowBattery, force: preview,
            warning: presentation, accessoryEvent: event)
    }
    @MainActor
    func updateAccessoryConnectionBattery(_ event: AccessoryConnectionEvent) {
        guard let active = activeAccessoryConnection, active.kind == .mouse, event.kind == .mouse,
              active.address == event.address, active.connected, event.connected,
              event.main != nil, active != event,
              coordinator.expandingView.show, coordinator.expandingView.type == .battery else { return }
        activeAccessoryConnection = event
        if let duration = mouseBatteryClock?.resolveBattery() {
            mouseBatteryFallback?.cancel()
            coordinator.setBatteryAutoHide(after: duration)
        }
    }

    @MainActor
    func dismissAccessoryConnection(address: String? = nil) {
        guard let active = activeAccessoryConnection, address == nil || active.address == address,
              coordinator.expandingView.show, coordinator.expandingView.type == .battery else { return }
        mouseBatteryFallback?.cancel()
        mouseBatteryClock = nil
        coordinator.toggleExpandingView(status: false, type: .battery)
    }

    private func presentTemporaryBatteryHUDIfNeeded(
        kind: BatteryTemporaryHUDKind,
        force: Bool,
        levelOverride: Int? = nil,
        lowPowerModeOverride: Bool? = nil,
        warning: LowBatteryWarning? = nil,
        airPodsReading: AirPodsBatteryReading? = nil,
        accessoryEvent: AccessoryConnectionEvent? = nil
    ) {
        guard force || ((airPodsReading != nil || accessoryEvent != nil) ? Defaults[.enableSystemHUD] : Defaults[.showPowerStatusNotifications]) else { return }

        let duration: Int
        let isEnabled: Bool

        switch kind {
        case .charging:
            duration = Defaults[.chargingBatteryHUDDuration]
            isEnabled = Defaults[.showChargingBatteryHUD]
        case .lowBattery:
            duration = warning?.duration ?? Defaults[.lowBatteryHUDDuration]
            isEnabled = accessoryEvent != nil ? true : airPodsReading != nil ? Defaults[.airPodsBatteryWarningsEnabled] : Defaults[.showLowBatteryHUD]
        case .fullBattery:
            duration = Defaults[.fullBatteryHUDDuration]
            isEnabled = Defaults[.showFullBatteryHUD]
        case .lowPowerEnabled:
            duration = Defaults[.lowPowerEnabledBatteryHUDDuration] ?? Defaults[.chargingBatteryHUDDuration]
            isEnabled = Defaults[.showChargingBatteryHUD]
        case .lowPowerDisabled:
            duration = Defaults[.lowPowerDisabledBatteryHUDDuration] ?? Defaults[.chargingBatteryHUDDuration]
            isEnabled = Defaults[.showChargingBatteryHUD]
        case .unplugged:
            duration = Defaults[.unpluggedBatteryHUDDuration] ?? Defaults[.chargingBatteryHUDDuration]
            isEnabled = Defaults[.showChargingBatteryHUD]
        }

        guard force || isEnabled else { return }

        mouseBatteryFallback?.cancel()
        mouseBatteryClock = accessoryEvent?.kind == .mouse && accessoryEvent?.connected == true
            ? MouseBatteryPresentationClock(duration: duration, hasBattery: accessoryEvent?.main != nil) : nil
        let hideDelay = mouseBatteryClock?.initialHideDelay ?? TimeInterval(max(1, duration))
        let targetScreenName = resolvedTemporaryHUDTargetScreenName()
        if force {
            previewCanvasCleanup?.cancel()
            previewCanvasActive = true
            coordinator.suppressHoverOpen(for: 0.6)
            NotificationCenter.default.post(name: .notchflowPrepareBatteryPreview, object: nil,
                userInfo: targetScreenName.map { ["screenName": $0] })
            previewCanvasCleanup = Task { [weak self] in
                try? await Task.sleep(for: .seconds(TimeInterval(max(1, duration)) + 0.6))
                guard !Task.isCancelled else { return }
                self?.previewCanvasActive = false
            }
        }
        isAccessoryConnectionPreview = force && accessoryEvent != nil
        activeAccessoryConnection = accessoryEvent
        activeAirPodsBatteryWarning = airPodsReading
        activeTemporaryHUDStyleOverride = warning?.presentation.style
        activeTemporaryHUDIsCritical = warning?.presentation == .critical
        activeTemporaryHUDKind = kind
        activeTemporaryHUDToken = UUID()
        activeTemporaryHUDTargetScreenName = targetScreenName
        activeTemporaryHUDLevelOverride = levelOverride
        activeTemporaryHUDLowPowerModeOverride = lowPowerModeOverride
        if kind == .lowBattery && warning?.presentation == .critical {
            CriticalBatteryBorderManager.shared.show(screenName: targetScreenName, duration: TimeInterval(max(1, duration)))
        } else {
            CriticalBatteryBorderManager.shared.dismiss()
        }
        coordinator.toggleExpandingView(
            status: true,
            type: .battery,
            autoHideDuration: hideDelay
        )
        if mouseBatteryClock?.waitingForBattery == true {
            let token = activeTemporaryHUDToken
            mouseBatteryFallback = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(MouseBatteryPresentationClock.unavailableTimeout))
                guard let self, !Task.isCancelled, self.activeTemporaryHUDToken == token,
                      self.activeAccessoryConnection?.kind == .mouse,
                      let duration = self.mouseBatteryClock?.resolveUnavailable() else { return }
                // An unsupported/unavailable battery must not leave a permanent
                // card. Give the unavailable result the same configured read time.
                self.coordinator.setBatteryAutoHide(after: duration)
            }
        }
    }

    private func resolvedTemporaryHUDTargetScreenName() -> String? {
        if Defaults[.showOnAllDisplays] {
            return nil
        }

        let preferredNames = [
            coordinator.selectedScreen,
            coordinator.preferredScreen,
            NSScreen.main?.localizedName
        ]
        .compactMap { $0 }

        for candidate in preferredNames where NSScreen.screens.contains(where: { $0.localizedName == candidate }) {
            return candidate
        }

        return NSScreen.screens.first?.localizedName
    }

    private func preferredDynamicIslandTargetScreenName() -> String? {
        let mainScreenName = NSScreen.main?.localizedName
        let preferredNames = [coordinator.selectedScreen, coordinator.preferredScreen]

        for candidate in preferredNames where shouldUseDynamicIslandMode(for: candidate) {
            return candidate
        }

        if let externalDynamicIslandScreen = NSScreen.screens.first(where: {
            $0.localizedName != mainScreenName && shouldUseDynamicIslandMode(for: $0.localizedName)
        }) {
            return externalDynamicIslandScreen.localizedName
        }

        if let anyDynamicIslandScreen = NSScreen.screens.first(where: {
            shouldUseDynamicIslandMode(for: $0.localizedName)
        }) {
            return anyDynamicIslandScreen.localizedName
        }

        return nil
    }

    private func handleLowBatteryAlertIfNeeded(previousLevel: Float, newLevel: Float) {
        guard managerBattery.hasBattery() else { return }
        let warning = lowBatteryWarningTracker.update(previous: previousLevel, current: newLevel,
            connectedToPower: isPluggedIn, warnings: Defaults[.lowBatteryWarnings])
        saveLowBatteryWarningState()
        guard let warning else { return }
        guard Defaults[.showPowerStatusNotifications], Defaults[.showLowBatteryHUD] else { return }
        self.statusText = warning.presentation == .critical ? String(localized: "Battery critically low") : String(localized: "Low battery")
        presentTemporaryBatteryHUDIfNeeded(kind: .lowBattery, force: false, warning: warning)
        if warning.sound && Defaults[.playLowBatteryAlertSound] {
            playLowBatteryAlertSound()
        }
    }

    private func saveLowBatteryWarningState() {
        let delivered = lowBatteryWarningTracker.delivered.sorted()
        if Defaults[.deliveredLowBatteryWarnings] != delivered {
            Defaults[.deliveredLowBatteryWarnings] = delivered
        }
    }

    private func handleFullBatteryAlertIfNeeded(previousLevel: Float, newLevel: Float) {
        guard newLevel > previousLevel else { return }
        let threshold = Float(Defaults[.fullBatteryHUDThreshold])
        guard previousLevel < threshold && newLevel >= threshold else { return }

        self.statusText = String(localized: "Full charge")
        presentTemporaryBatteryHUDIfNeeded(kind: .fullBattery)
    }

    private func playLowBatteryAlertSound() {
        lowBatteryAlertSoundPlayer.play(fileName: "lowbattery", fileExtension: "mp3")
    }

    deinit {
        print("🔌 Cleaning up battery monitoring...")
        if let managerBatteryId: Int = managerBatteryId {
            managerBattery.removeObserver(byId: managerBatteryId)
        }
    }

}
