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

extension Notification.Name {
    static let keyboardBacklightDidChange = Notification.Name("NotchFlow.keyboardBacklightDidChange")
}

final class SystemKeyboardBacklightController {
    static let shared = SystemKeyboardBacklightController()

    var onBacklightChange: ((Float) -> Void)?

    private let workerQueue = DispatchQueue(label: "com.kayhsen.NotchFlow.keyboardBacklight", qos: .userInitiated)
    private let notificationCenter = NotificationCenter.default
    private var isRunning = false
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var lastObservedLevel: Float?
    private var lastReportedLevel: Float?
    private var lastReportDate: Date = .distantPast
    private let pollInterval: TimeInterval = 0.5
    private let minimumReportInterval: TimeInterval = 1.5
    private let minimumVisibleChange: Float = 0.03

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        readCurrentLevel(showHUD: false)
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.readCurrentLevel(showHUD: true)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        pollInFlight = false
    }

    func adjust(by delta: Float) {
        let target = currentLevel + delta
        setLevel(target)
    }

    func setLevel(_ value: Float) {
        let clamped = max(0, min(1, value))
        workerQueue.async {
            do {
                try KeyboardBrightnessSensor.setLevel(clamped)
                let level = (try? KeyboardBrightnessSensor.currentLevel()) ?? clamped
                self.emitChange(level: level)
            } catch {
                NSLog("⚠️ Failed to set keyboard backlight: \(error)")
            }
        }
    }

    var currentLevel: Float {
        (try? KeyboardBrightnessSensor.currentLevel()) ?? 0
    }

    private func readCurrentLevel(showHUD: Bool) {
        guard isRunning, !pollInFlight else { return }
        pollInFlight = true
        workerQueue.async {
            let level = try? KeyboardBrightnessSensor.currentLevel()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pollInFlight = false
                guard self.isRunning, let level else { return }
                self.observe(level: level, showHUD: showHUD)
            }
        }
    }

    private func observe(level: Float, showHUD: Bool) {
        let clamped = max(0, min(1, level))
        let previous = lastObservedLevel
        lastObservedLevel = clamped
        guard showHUD, previous != nil else {
            lastReportedLevel = clamped
            return
        }
        guard abs(clamped - (lastReportedLevel ?? previous ?? clamped)) >= minimumVisibleChange,
              Date().timeIntervalSince(lastReportDate) >= minimumReportInterval else { return }
        emitChange(level: clamped)
    }

    private func emitChange(level: Float) {
        guard isRunning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.lastObservedLevel = level
            self.lastReportedLevel = level
            self.lastReportDate = Date()
            self.onBacklightChange?(level)
            self.notificationCenter.post(name: .keyboardBacklightDidChange, object: nil, userInfo: ["value": level])
        }
    }
}
