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
import Combine
import AppKit
import Defaults
import SwiftUI
import CoreGraphics

@MainActor
class CapsLockManager: ObservableObject {
    static let shared = CapsLockManager()
    
    @Published var isCapsLockActive: Bool = false
    
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var reconciliationTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private let coordinator = DynamicIslandViewCoordinator.shared
    private let capsLockAnimation = Animation.spring(response: 0.32, dampingFraction: 0.85)
    
    private init() {
        // Get initial state
        isCapsLockActive = Self.keyboardCapsLockIsActive
        
        // Monitor flag changes when app is focused
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.reconcileKeyboardState()
            return event
        }
        
        // Monitor flag changes globally (even when app is not focused)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.reconcileKeyboardState()
            }
        }
        
        // Event delivery can be missed across focus/wake changes; synthetic
        // modifier snapshots must not latch a persistent indicator indefinitely.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcileKeyboardState() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        reconciliationTimer = timer
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reconcileKeyboardState() }
                .store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileKeyboardState() }
            .store(in: &subscriptions)

        print("CapsLockManager: ✅ Initialized with Caps Lock \(isCapsLockActive ? "ON" : "OFF")")
    }
    
    deinit {
        reconciliationTimer?.invalidate()
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private static var keyboardCapsLockIsActive: Bool {
        CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    }

    private func reconcileKeyboardState() {
        let newState = Self.keyboardCapsLockIsActive
        let changed = newState != isCapsLockActive
        if changed {
            withAnimation(capsLockAnimation) {
                isCapsLockActive = newState
            }
        }

        if !newState {
            // Clear even if the local state was already OFF. Never overwrite a
            // newer volume, Bluetooth or other event while retiring Caps Lock.
            if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .capsLock {
                var updated = coordinator.sneakPeek
                updated.show = false
                withAnimation(capsLockAnimation) { coordinator.sneakPeek = updated }
            }
        } else if changed && Defaults[.enableCapsLockIndicator] {
            coordinator.toggleSneakPeek(
                status: true,
                type: .capsLock,
                duration: .infinity,
                value: 1.0,
                icon: ""
            )
        }
    }
}
