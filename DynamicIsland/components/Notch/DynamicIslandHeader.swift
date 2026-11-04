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

import Defaults
import SwiftUI

struct DynamicIslandHeader: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @EnvironmentObject var webcamManager: WebcamManager
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject private var recordingManager = ScreenRecordingManager.shared
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @ObservedObject var shelfState = ShelfStateViewModel.shared
    @ObservedObject var timerManager = TimerManager.shared
    @ObservedObject var doNotDisturbManager = DoNotDisturbManager.shared
    @ObservedObject var caffeinateManager = CaffeinateManager.shared
    @State private var showHeaderOverflow = false
    @State private var showClipboardPopover = false
    @State private var showTimerPopover = false
    @State private var showPerAppVolumePopover = false
    @State private var showCaffeinatePopover = false
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.timerDisplayMode) var timerDisplayMode
    @Default(.showClipboardIcon) var showClipboardIcon
    @Default(.enablePerAppVolume) var enablePerAppVolume
    @Default(.showPerAppVolumeIcon) var showPerAppVolumeIcon
    @Default(.enableCaffeinate) var enableCaffeinate
    @Default(.showCaffeinateIcon) var showCaffeinateIcon
    @Default(.clipboardDisplayMode) var clipboardDisplayMode
    @Default(.showBatteryIndicator) var showBatteryIndicator
    
    /// Point size per symbol, so the row reads as one size.
    ///
    /// Equal point size is equal *cap height*, which is not equal optical size.
    /// Measured at 15pt medium: `gearshape` covers 289pt² of ink against
    /// `web.camera`'s 208 — 39% more — and `list.clipboard` stands 19pt tall
    /// against `timer`'s 16. These sizes were solved so every glyph lands on
    /// 16pt of ink height, which is what actually makes a mixed row look even.
    private static let headerGlyphSizes: [String: CGFloat] = [
        "web.camera": 14.5,
        "list.clipboard": 13,
        "eyedropper": 14.3,
        "timer": 14.4,
        "gearshape": 14.2,
        // Not solved against measured ink the way the others were: the three
        // sliders stand slightly taller than `timer`, so this trims to match.
        "slider.vertical.3": 13.8,
        // Unlike the sizes above, these two were not solved against measured
        // ink height -- they are the row default, nudged down because the cup
        // glyph carries a saucer and so reads a shade wider than `timer`.
        "cup.and.saucer": 14.0,
        "cup.and.saucer.fill": 14.0
    ]

    /// One glyph in the header row, on a common centre.
    ///
    /// The 20pt box clears the largest frame any of these symbols asks for
    /// (19pt, `list.clipboard`), so none of them is clipped — a smaller box
    /// silently cuts the tall ones.
    private func headerGlyph(_ name: String, color: Color = .white) -> some View {
        Image(systemName: name)
            .foregroundColor(color)
            .font(.system(size: Self.headerGlyphSizes[name] ?? 14.4, weight: .medium))
            .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private var accessoryButtons: some View {
                    clipboardHeaderButton

                    if Defaults[.showMirror] {
                        Button(action: {
                            vm.toggleCameraPreview()
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    headerGlyph("web.camera")
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    if Defaults[.enableTimerFeature] && timerDisplayMode == .popover {
                        Button(action: {
                            withAnimation(.smooth) {
                                showTimerPopover.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    headerGlyph("timer")
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showTimerPopover, arrowEdge: .bottom) {
                            TimerPopover()
                        }
                        .onChange(of: showTimerPopover) { isActive in
                            vm.isTimerPopoverActive = isActive
                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                    }
                    
                    if enablePerAppVolume && showPerAppVolumeIcon {
                        Button(action: {
                            withAnimation(.smooth) {
                                showPerAppVolumePopover.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    headerGlyph("slider.vertical.3")
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showPerAppVolumePopover, arrowEdge: .bottom) {
                            PerAppVolumePopover()
                        }
                        .onChange(of: showPerAppVolumePopover) { isActive in
                            vm.isPerAppVolumePopoverActive = isActive

                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                    }

                    if enableCaffeinate && showCaffeinateIcon {
                        Button(action: {
                            withAnimation(.smooth) {
                                showCaffeinatePopover.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    // Tinting the active state is the only
                                    // signal the closed row can give that the
                                    // Mac is being held awake, so it is not
                                    // just a filled-vs-hollow glyph swap.
                                    headerGlyph(
                                        caffeinateManager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                                        color: caffeinateManager.isActive ? .yellow : .white
                                    )
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showCaffeinatePopover, arrowEdge: .bottom) {
                            CaffeinatePopover()
                        }
                        .onChange(of: showCaffeinatePopover) { isActive in
                            vm.isCaffeinatePopoverActive = isActive

                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                    }

                    if Defaults[.settingsIconInNotch] {
                        Button(action: {
                            SettingsWindowController.shared.showWindow()
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    headerGlyph("gearshape")
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    

    }

    private var selectedScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.localizedName == coordinator.selectedScreen }) ?? NSScreen.main
    }

    /// The centre spacer follows the physical camera housing even when the
    /// user has configured a narrower closed notch. This prevents the weather
    /// capsule and header buttons from being laid out underneath the hardware.
    private var headerNotchClearanceWidth: CGFloat {
        let screen = selectedScreen
        let physicalWidth = screen.flatMap { PhysicalNotchLayout.measuredWidth(for: $0) }

        return NotchHeaderLayout.deadSpaceWidth(
            configuredWidth: vm.closedNotchSize.width,
            physicalWidth: physicalWidth,
            hasPhysicalNotch: (screen?.safeAreaInsets.top ?? 0) > 0
        )
    }

    var body: some View {
        GeometryReader { geometry in
        let wingWidth = max(0, (geometry.size.width - headerNotchClearanceWidth) / 2)
        HStack(spacing: 0) {
            HStack {
                let shouldShowTabs = coordinator.alwaysShowTabs || vm.notchState == .open || !shelfState.items.isEmpty
                if shouldShowTabs {
                    TabSelectionView()
                }
            }
            .frame(width: max(0, wingWidth - 16), alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .animation(.smooth.delay(0.1), value: vm.notchState)
            .zIndex(2)
            .padding(8)

            if vm.notchState == .open {
                Color.clear
                    .frame(width: headerNotchClearanceWidth)
                    .accessibilityHidden(true)
            }

            // 30pt targets sitting 4pt apart read as one run of buttons rather
            // than as separate ones; 8 is the gap Apple leaves between controls
            // of this size.
            HStack(spacing: wingWidth < 260 ? 4 : 8) {
                if vm.notchState == .open {
                    if Defaults[.enableScreenRecordingDetection] && Defaults[.showRecordingIndicator]
                        && recordingManager.isRecording {
                        // Status belongs in the visible row, never its overflow.
                        RecordingIndicator()
                            .frame(width: 12, height: 30)
                            .layoutPriority(3)
                            .help("Screen recording in progress")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Screen recording in progress")
                    }
                    CompactNotchWeatherView(compact: wingWidth < 260)
                        .layoutPriority(2)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { accessoryButtons }
                            .fixedSize()
                        Button {
                            showHeaderOverflow.toggle()
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More notch controls")
                        .popover(isPresented: $showHeaderOverflow, arrowEdge: .bottom) {
                            HStack(spacing: 8) { accessoryButtons }
                                .padding(12)
                                .background(.black)
                        }
                    }

                    if Defaults[.enableDoNotDisturbDetection]
                        && Defaults[.showDoNotDisturbIndicator]
                        && doNotDisturbManager.isDoNotDisturbActive
                        && !shouldSuppressStatusIndicators {
                        FocusIndicator()
                            .frame(width: wingWidth < 260 ? 22 : 30, height: 30)
                            .transition(.opacity)
                    }
                }

                if vm.notchState == .open && showBatteryIndicator {
                    DynamicIslandBatteryView(
                        batteryWidth: 30,
                        isCharging: batteryModel.isCharging,
                        isInLowPowerMode: batteryModel.isInLowPowerMode,
                        isPluggedIn: batteryModel.isPluggedIn,
                        levelBattery: batteryModel.levelBattery,
                        maxCapacity: batteryModel.maxCapacity,
                        timeToFullCharge: batteryModel.timeToFullCharge,
                        timeToEmpty: batteryModel.timeToEmpty,
                        isForNotification: false
                    )
                }

            }
            .font(.system(.headline, design: .rounded))
            .frame(width: wingWidth, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .animation(.smooth.delay(0.1), value: vm.notchState)
            .zIndex(2)
        }
        }
        .onChange(of: showHeaderOverflow) { _, active in
            vm.isHeaderOverflowPopoverActive = active
            if !active { vm.shouldRecheckHover.toggle() }
        }
        .onDisappear { vm.isHeaderOverflowPopoverActive = false }
        .foregroundColor(.gray)
        .environmentObject(vm)
        .onChange(of: coordinator.shouldToggleClipboardPopover) { _ in
            // Only toggle if clipboard is enabled
            if Defaults[.enableClipboardManager] {
                switch clipboardDisplayMode {
                case .panel:
                    ClipboardPanelManager.shared.toggleClipboardPanel()
                case .popover:
                    showClipboardPopover.toggle()
                case .separateTab:
                    if coordinator.currentView == .notes {
                        coordinator.currentView = .home
                    } else {
                        coordinator.currentView = .notes
                    }
                case .notchTab:
                    // Same as the header button: don't let the armed auto-close fire after
                    // we switch into the clipboard tab.
                    AppDelegate.shared?.cancelPendingNotchAutoClose()
                    if coordinator.currentView == .clipboard {
                        coordinator.currentView = .home
                    } else {
                        coordinator.currentView = .clipboard
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleClipboardPopover"))) { _ in
            // Handle keyboard shortcut for popover mode
            if Defaults[.enableClipboardManager] && clipboardDisplayMode == .popover {
                showClipboardPopover.toggle()
            }
        }
        .onChange(of: enablePerAppVolume) { _, newValue in
            if !newValue {
                showPerAppVolumePopover = false
                vm.isPerAppVolumePopoverActive = false
            }
        }
        .onChange(of: enableCaffeinate) { _, newValue in
            if !newValue {
                showCaffeinatePopover = false
                vm.isCaffeinatePopoverActive = false
            }
        }
        .onChange(of: enableTimerFeature) { _, newValue in
            if !newValue {
                showTimerPopover = false
                vm.isTimerPopoverActive = false
            }
        }
        .onChange(of: timerDisplayMode) { _, mode in
            if mode == .tab {
                showTimerPopover = false
                vm.isTimerPopoverActive = false
            }
        }
    }
}

private extension DynamicIslandHeader {
    @ViewBuilder
    var clipboardHeaderButton: some View {
        if Defaults[.enableClipboardManager]
            && showClipboardIcon
            && clipboardDisplayMode != .separateTab {
            Button(action: {
                switch clipboardDisplayMode {
                case .panel:
                    ClipboardPanelManager.shared.toggleClipboardPanel()
                case .popover:
                    showClipboardPopover.toggle()
                case .separateTab:
                    coordinator.currentView = .notes
                case .notchTab:
                    AppDelegate.shared?.cancelPendingNotchAutoClose()
                    coordinator.currentView = (coordinator.currentView == .clipboard) ? .home : .clipboard
                }
            }) {
                Capsule()
                    .fill(.black)
                    .frame(width: 30, height: 30)
                    .overlay {
                        headerGlyph("list.clipboard")
                    }
            }
            .buttonStyle(PlainButtonStyle())
            .fixedSize()
            .popover(isPresented: $showClipboardPopover, arrowEdge: .bottom) {
                ClipboardPopover()
            }
            .onChange(of: showClipboardPopover) { isActive in
                vm.isClipboardPopoverActive = isActive
                if !isActive {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        vm.shouldRecheckHover.toggle()
                    }
                }
            }
            .onAppear {
                if !clipboardManager.isMonitoring {
                    clipboardManager.startMonitoring()
                }
            }
        }
    }
}

private struct CompactNotchWeatherView: View {
    @ObservedObject private var weatherManager = LockScreenWeatherManager.shared
    var compact = false

    var body: some View {
        Group {
            if let snapshot = weatherManager.snapshot {
                let temperature = snapshot.temperatureText.replacingOccurrences(of: "°", with: "")
                    + (snapshot.temperatureInfo?.unitSymbol ?? Defaults[.lockScreenWeatherTemperatureUnit].symbol)
                Button {
                    DynamicIslandViewCoordinator.shared.currentView = .weather
                    Task { _ = await weatherManager.refresh() }
                } label: {
                HStack(spacing: 5) {
                    Image(systemName: snapshot.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))

                    VStack(alignment: .leading, spacing: -1) {
                        Text(temperature)
                            .font(.system(size: compact ? 10 : 11, weight: .semibold))
                            .foregroundStyle(.white)
                        if !snapshot.description.isEmpty {
                            Text(snapshot.description.localizedCapitalized)
                                .font(.system(size: compact ? 7.5 : 8.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                }
                .frame(width: compact ? 82 : 66)
                .padding(.horizontal, 5)
                .frame(height: 30)
                .background(Color.white.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(temperature), \(snapshot.description). Show weather details")
                .help(snapshot.locationName ?? String(localized: "Current weather"))
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }
}

struct NotchWeatherView: View {
    @ObservedObject private var weatherManager = LockScreenWeatherManager.shared

    var body: some View {
        ScrollView {
            if let weather = weatherManager.snapshot {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        Button {
                            DynamicIslandViewCoordinator.shared.currentView = .home
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 22, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back to home")
                        Image(systemName: weather.symbolName)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 34))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(weather.locationName ?? String(localized: "Current location"))
                                .font(.headline)
                            Text(weather.description.localizedCapitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(weather.temperatureText)
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                    }

                    HStack(spacing: 18) {
                        if let low = weather.temperatureInfo?.displayMinimum,
                           let high = weather.temperatureInfo?.displayMaximum {
                            detail("High / Low", value: "\(high)° / \(low)°")
                        }
                        if let feelsLike = weather.details?.feelsLike {
                            detail("Feels like", value: "\(Int(round(feelsLike)))°")
                        }
                        if let chance = weather.details?.precipitationProbability {
                            detail("Rain", value: "\(chance)%")
                        }
                        if let humidity = weather.details?.humidity {
                            detail("Humidity", value: "\(humidity)%")
                        }
                        if let wind = weather.details?.windSpeed {
                            detail("Wind", value: "\(Int(round(wind))) \(weather.details?.windSpeedUnit ?? "km/h")")
                        }
                        if let air = weather.airQuality {
                            detail("Air", value: "\(air.index) · \(air.category.displayName)")
                        }
                    }

                    if let hourly = weather.details?.hourly, !hourly.isEmpty {
                        Divider().overlay(.white.opacity(0.15))
                        HStack(spacing: 0) {
                            ForEach(Array(hourly.enumerated()), id: \.offset) { _, hour in
                                VStack(spacing: 3) {
                                    Text(hour.time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: hour.symbolName)
                                        .symbolRenderingMode(.multicolor)
                                    Text("\(Int(round(hour.temperature)))°")
                                        .font(.caption.weight(.semibold))
                                    if let rain = hour.precipitationProbability {
                                        Text("\(rain)%")
                                            .font(.caption2)
                                            .foregroundStyle(.cyan)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(16)
            } else {
                ProgressView("Loading weather…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { _ = await weatherManager.refresh(force: true) }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    private func detail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
    }
}

private extension DynamicIslandHeader {
    var shouldSuppressStatusIndicators: Bool {
        Defaults[.settingsIconInNotch]
            && Defaults[.enableClipboardManager]
            && Defaults[.showClipboardIcon]
            && Defaults[.enableTimerFeature]
    }
}

#Preview {
    DynamicIslandHeader()
        .environmentObject(DynamicIslandViewModel())
        .environmentObject(WebcamManager.shared)
}
