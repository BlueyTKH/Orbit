import AppKit
import ApplicationServices
import Combine
import Defaults

/// Conservative matching: a low-battery phrase alone cannot identify the Mac.
enum MacNativeBatteryAlertMatcher {
    static let owners: Set<String> = ["com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.UserNotificationCenter", "com.apple.SystemUIServer"]
    static func matches(owner: String, texts: [String], width: CGFloat, height: CGFloat) -> Bool {
        guard owners.contains(owner), (100...650).contains(width), (28...190).contains(height) else { return false }
        let text = texts.joined(separator: " ").lowercased()
        guard !["airpods", "iphone", "ipad", "mouse", "keyboard", "headphone"].contains(where: text.contains) else { return false }
        let low = text.contains("low battery") || text.contains("battery is low") || text.contains("battery running low")
        let mac = text.contains("your mac") || text.contains("macbook") || text.contains("mac battery")
        return low && mac
    }
}

@MainActor final class MacNativeBatteryAlertManager {
    static let shared = MacNativeBatteryAlertManager()
    private let native = AirPodsSystemAlertReplacement()
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var started = false
    func start() {
        guard !started else { return }; started = true
        Defaults.publisher(.replaceSystemMacBatteryWarnings).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        BatteryStatusViewModel.shared.objectWillChange.debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }
    private func update() {
        let battery = BatteryStatusViewModel.shared
        let enabled = Defaults[.replaceSystemMacBatteryWarnings] && Defaults[.enableSystemHUD]
            && Defaults[.lowBatteryWarnings].contains(where: { $0.enabled }) && !battery.isPluggedIn
            && battery.levelBattery <= 20 && !LockScreenManager.shared.isLocked && AXIsProcessTrusted()
        native.setReadings([], macEnabled: enabled)
    }
}
