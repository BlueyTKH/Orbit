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

import SwiftUI
import Defaults
import ServiceManagement

@objc private protocol NotchFlowLowPowerService {
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

private enum LowPowerModeHelperClient {
    static let serviceName = "com.kayhsen.NotchFlow.lowpower"
    static let servicePlist = "com.kayhsen.NotchFlow.LowPowerHelper.plist"

    static func setEnabled(_ enabled: Bool) -> (Bool, String?) {
        let service = SMAppService.daemon(plistName: servicePlist)
        do {
            if service.status != .enabled {
                try service.register()
            }
        } catch {
            SMAppService.openSystemSettingsLoginItems()
            return (false, "Orbit needs one-time approval for its Low Power Mode helper. Open System Settings → General → Login Items and allow NotchFlow, then try again. (\(error.localizedDescription))")
        }

        guard service.status == .enabled else {
            SMAppService.openSystemSettingsLoginItems()
            return (false, "Allow Orbit’s Low Power Mode helper in System Settings → General → Login Items, then try again.")
        }

        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: NotchFlowLowPowerService.self)
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: (Bool, String?) = (false, "Orbit’s Low Power Mode helper did not respond.")
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            resultLock.lock()
            result = (false, error.localizedDescription)
            resultLock.unlock()
            semaphore.signal()
        } as? NotchFlowLowPowerService

        guard let proxy else {
            return (false, "Orbit could not connect to its Low Power Mode helper.")
        }

        proxy.setLowPowerMode(enabled) { success, message in
            resultLock.lock()
            result = (success, message)
            resultLock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 10) == .success else {
            return (false, "Orbit’s Low Power Mode helper timed out.")
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        return result
    }
}

@MainActor
final class LowPowerModeController: ObservableObject {
    static let shared = LowPowerModeController()

    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?

    private init() {}

    func setEnabled(_ enabled: Bool) {
        guard !isApplying else { return }
        isApplying = true
        errorMessage = nil

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LowPowerModeHelperClient.setEnabled(enabled)
            }.value

            isApplying = false
            if !result.0 {
                errorMessage = result.1?.isEmpty == false
                    ? result.1
                    : String(localized: "Low Power Mode could not be changed.")
            }
        }
    }
}

/// Explicit status priority keeps the warning visible when power states overlap.
enum BatteryIconState: Equatable {
    case lowCharge, lowPower, charging, battery

    static func resolve(level: Float, charging: Bool, lowPower: Bool) -> Self {
        if level.isFinite && level < 20 { return .lowCharge }
        if lowPower { return .lowPower }
        if charging { return .charging }
        return .battery
    }

    var color: Color {
        switch self {
        case .lowCharge: return .red
        case .lowPower: return .yellow
        case .charging: return .green
        case .battery: return .white
        }
    }
}

/// Rounded, percentage-filled battery with native SF power symbols.
struct BatteryView: View {
    var levelBattery: Float
    var isPluggedIn: Bool
    var isCharging: Bool
    var isInLowPowerMode: Bool
    var batteryWidth: CGFloat = 26
    var isForNotification: Bool

    var batteryColor: Color {
        BatteryIconState.resolve(level: levelBattery, charging: isCharging,
                                 lowPower: isInLowPowerMode).color
    }

    private var safeLevel: CGFloat {
        levelBattery.isFinite ? min(max(CGFloat(levelBattery), 0), 100) : 0
    }

    private var statusSymbol: String? {
        if isCharging { return "bolt.fill" }
        if isPluggedIn { return "powerplug.portrait.fill" }
        return nil
    }

    var body: some View {
        let height = batteryWidth * 0.52
        let inset: CGFloat = 1.25
        let radius = height * 0.29
        let interiorWidth = batteryWidth - 2 * inset
        let filledWidth = safeLevel > 0 ? max(2, interiorWidth * safeLevel / 100) : 0

        HStack(spacing: height * 0.11) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.white.opacity(0.20))

                RoundedRectangle(cornerRadius: max(1, radius - inset), style: .continuous)
                    .fill(batteryColor)
                    .frame(width: filledWidth, height: height - inset * 2)
                    .padding(inset)

                // The glyph changes contrast precisely where it crosses the
                // charge fill, staying readable at low levels and in white.
                glyph(height: height)
                    .foregroundStyle(.white)
                glyph(height: height)
                    .foregroundStyle(.black.opacity(0.88))
                    .mask(alignment: .leading) {
                        RoundedRectangle(cornerRadius: max(1, radius - inset), style: .continuous)
                            .frame(width: filledWidth, height: height - inset * 2)
                            .padding(inset)
                    }

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.65), lineWidth: 0.75)
            }
            .frame(width: batteryWidth, height: height)

            RoundedRectangle(cornerRadius: height * 0.09, style: .continuous)
                .fill(.white.opacity(0.65))
                .frame(width: height * 0.11, height: height * 0.36)
        }
        .animation(.smooth(duration: 0.3), value: levelBattery)
        .animation(.smooth(duration: 0.3), value: batteryColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(Int(safeLevel)) percent")
        .accessibilityValue(isCharging ? "Charging" : isPluggedIn ? "Connected to power" : "On battery")
    }

    private func glyph(height: CGFloat) -> some View {
        HStack(spacing: height * 0.07) {
            Text("\(Int(safeLevel))")
                .font(.system(size: height * 0.60, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            if let statusSymbol {
                Image(systemName: statusSymbol)
                    .font(.system(size: height * 0.46, weight: .semibold))
            }
        }
        .frame(width: batteryWidth - 4, height: height, alignment: .center)
        .frame(width: batteryWidth, height: height)
    }
}

/// A view that displays detailed battery information and settings.
struct BatteryMenuView: View {
    
    var isPluggedIn: Bool
    var isCharging: Bool
    var levelBattery: Float
    var maxCapacity: Float
    var timeToFullCharge: Int
    var timeToEmpty: Int
    var isInLowPowerMode: Bool
    var onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @ObservedObject private var lowPowerController = LowPowerModeController.shared
    @Default(.statsUpdateInterval) private var statsUpdateInterval
    @State private var diagnostics = MacBatteryManager.BatteryDiagnostics.unavailable
    @State private var systemHealth: MacBatteryManager.SystemHealthReport?

    private var diagnosticsRefreshInterval: TimeInterval {
        min(max(statsUpdateInterval, 1), 60)
    }

    private var etaText: String? {
        if isCharging, timeToFullCharge > 0 {
            return String(localized: "\(MacBatteryManager.format(minutes: timeToFullCharge)) until fully charged")
        }
        if !isPluggedIn, timeToEmpty > 0 {
            return String(localized: "About \(MacBatteryManager.format(minutes: timeToEmpty)) remaining")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack {
                Text("Battery Status")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(Int(levelBattery))%")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                if let etaText {
                    Label(etaText, systemImage: "clock.fill")
                        .font(.subheadline.weight(.semibold))
                }
                if isInLowPowerMode {
                    Label("Low Power Mode", systemImage: "bolt.circle")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isCharging {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isPluggedIn {
                    Label("Plugged In", systemImage: "powerplug.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if !isCharging && isPluggedIn && levelBattery >= 80 {
                    Label("Charging on Hold: Desktop Mode", systemImage: "desktopcomputer")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                    
            }
            .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("Battery Details", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))

                if diagnostics.hasBattery {
                    detailRow("Condition", systemHealth?.condition ?? "Unavailable")
                    detailRow(
                        "Maximum Capacity",
                        (systemHealth?.maximumCapacityPercent ?? diagnostics.calculatedHealthPercent)
                            .map { "\($0)%" } ?? "Unavailable"
                    )
                    detailRow("Cycle Count", diagnostics.cycleCount.map(String.init) ?? "Unavailable")
                    detailRow("Voltage", diagnostics.voltageVolts.map { String(format: "%.2f V", $0) } ?? "Unavailable")
                    detailRow("Current", diagnostics.currentAmps.map { String(format: "%+.2f A", $0) } ?? "Unavailable")
                    detailRow("Battery Power", diagnostics.batteryPowerWatts.map { String(format: "%+.1f W", $0) } ?? "Unavailable")
                    if let adapterWatts = diagnostics.adapterWatts, adapterWatts > 0 {
                        detailRow("Power Adapter", "\(adapterWatts) W")
                    }
                } else {
                    Text("No internal battery detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button {
                lowPowerController.setEnabled(!isInLowPowerMode)
            } label: {
                HStack {
                    Label(
                        isInLowPowerMode ? "Turn Off Low Power Mode" : "Turn On Low Power Mode",
                        systemImage: isInLowPowerMode ? "bolt.slash.fill" : "bolt.fill"
                    )
                    Spacer()
                    if lowPowerController.isApplying {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(lowPowerController.isApplying)

            if let errorMessage = lowPowerController.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button(action: openBatteryPreferences) {
                Label("Battery Settings", systemImage: "gearshape")
                    .fontWeight(.regular)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
        .padding()
        .frame(width: 310)
        // The notch itself always renders as dark. A popover, however, follows
        // the system appearance. NSColor's semantic colours resolve against the
        // actual popover appearance and remain readable in both light and dark
        // mode instead of inheriting the notch's white foreground.
        .foregroundStyle(Color(nsColor: .labelColor))
        .onAppear {
            diagnostics = MacBatteryManager.shared.currentDiagnostics()
        }
        .onReceive(Timer.publish(every: diagnosticsRefreshInterval, on: .main, in: .common).autoconnect()) { _ in
            diagnostics = MacBatteryManager.shared.currentDiagnostics()
        }
        .task {
            let report = await Task.detached(priority: .utility) {
                MacBatteryManager.shared.systemHealthReport()
            }.value
            if !Task.isCancelled {
                systemHealth = report
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption)
    }

    private func openBatteryPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            openURL(url)
            onDismiss()
        }
    }
}


/// A view that displays the battery status and allows interaction to show detailed information.
struct DynamicIslandBatteryView: View {
    
    @State var batteryWidth: CGFloat = 26
    var isCharging: Bool = false
    var isInLowPowerMode: Bool = false
    var isPluggedIn: Bool = false
    var levelBattery: Float = 0
    var maxCapacity: Float = 0
    var timeToFullCharge: Int = 0
    var timeToEmpty: Int = 0
    @State var isForNotification: Bool = false
    
    @State private var showPopupMenu: Bool = false
    @State private var isPressed: Bool = false
    @State private var isHoveringPopover: Bool = false

    @EnvironmentObject var vm: DynamicIslandViewModel

    /// The header already communicates that this is the battery. Keep the
    /// visible value compact so a long localized suffix cannot resize the
    /// expanded notch or squeeze the battery into a different proportion.
    private var compactETAText: String? {
        if isCharging, timeToFullCharge > 0 {
            return MacBatteryManager.format(minutes: timeToFullCharge)
        }
        if !isPluggedIn, timeToEmpty > 0 {
            return MacBatteryManager.format(minutes: timeToEmpty)
        }
        return nil
    }

    private var etaAccessibilityText: String? {
        if isCharging, timeToFullCharge > 0 {
            return String(localized: "\(MacBatteryManager.format(minutes: timeToFullCharge)) to full")
        }
        if !isPluggedIn, timeToEmpty > 0 {
            return String(localized: "\(MacBatteryManager.format(minutes: timeToEmpty)) left")
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 5) {
            if let compactETAText {
                Text(compactETAText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            BatteryView(
                levelBattery: levelBattery,
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                isInLowPowerMode: isInLowPowerMode,
                batteryWidth: batteryWidth,
                isForNotification: isForNotification
            )
        }
        // An unavailable estimate must not reserve an empty slot. The header
        // anchors this view on the right; adjacent controls reclaim the space.
        .frame(width: compactETAText == nil ? batteryWidth + 3 : batteryWidth + 56, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            etaAccessibilityText.map { "Battery \(Int(levelBattery)) percent, \($0)" }
                ?? "Battery \(Int(levelBattery)) percent"
        )
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    withAnimation {
                        isPressed = false
                        showPopupMenu.toggle()
                    }
                }
        )
        .popover(
            isPresented: $showPopupMenu,
            arrowEdge: .bottom) {
            BatteryMenuView(
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                levelBattery: levelBattery,
                maxCapacity: maxCapacity,
                timeToFullCharge: timeToFullCharge,
                timeToEmpty: timeToEmpty,
                isInLowPowerMode: isInLowPowerMode,
                onDismiss: { 
                    showPopupMenu = false
                }
            )
            .onHover { hovering in
                isHoveringPopover = hovering
            }
        }
        .onChange(of: showPopupMenu) { _, _ in
            updateBatteryPopoverActiveState()
        }
        .onChange(of: isHoveringPopover) { _, _ in
            updateBatteryPopoverActiveState()
        }
        .animation(.smooth(duration: 0.25), value: compactETAText)
    }

    private func updateBatteryPopoverActiveState() {
        vm.isBatteryPopoverActive = showPopupMenu && isHoveringPopover
    }
}


private struct BatteryTemporaryHUDMetrics {
    let width: CGFloat
    let height: CGFloat
    let topRadius: CGFloat
    let bottomRadius: CGFloat
}

private extension BatteryTemporaryHUDKind {
    func metrics(
        style: BatteryNotificationStyle,
        closedNotchWidth: CGFloat,
        baseHeight: CGFloat
    ) -> BatteryTemporaryHUDMetrics {
        let surface = BatteryTemporaryHUDLayout.surface(kind: self, style: style,
            closed: CGSize(width: closedNotchWidth, height: baseHeight))
        let compactBaseRadius = max(baseHeight / 2, 16)
        let compactTopRadius = max(12, compactBaseRadius - 4)

        switch (self, style) {
        case (_, .compact):
            return BatteryTemporaryHUDMetrics(
                width: surface.width,
                height: surface.height,
                topRadius: compactTopRadius,
                bottomRadius: compactBaseRadius
            )
        case (.lowBattery, .standard):
            return BatteryTemporaryHUDMetrics(
                width: surface.width,
                height: surface.height,
                topRadius: 22,
                bottomRadius: 40
            )
        case (.fullBattery, .standard):
            return BatteryTemporaryHUDMetrics(
                width: surface.width,
                height: surface.height,
                topRadius: 18,
                bottomRadius: 36
            )
        case (.charging, .standard), (.lowPowerEnabled, .standard), (.lowPowerDisabled, .standard), (.unplugged, .standard):
            return BatteryTemporaryHUDMetrics(
                width: surface.width,
                height: surface.height,
                topRadius: 18,
                bottomRadius: 36
            )
        }
    }
}

enum BatteryCompactWarningLayout {
    static let extraWidth: CGFloat = 180
    static let outerPadding: CGFloat = 16
    static let cameraClearance: CGFloat = 6
    static let minimumLabelScale: CGFloat = 0.85
    static let wingWidth = extraWidth / 2 - outerPadding
    static let contentWidth = wingWidth - cameraClearance
}

private struct BatteryCompactStatusRow: View {
    let title: String
    let batteryLevel: Int
    let tint: Color
    var cameraGap: CGFloat? = nil
    var animateWarning = false

    @ViewBuilder
    var body: some View {
        if let cameraGap {
            // Fixed camera lane: the label cannot borrow width from the
            // centre when the warning appears or the percentage changes.
            HStack(spacing: 0) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(BatteryCompactWarningLayout.minimumLabelScale)
                    .frame(width: BatteryCompactWarningLayout.contentWidth, alignment: .leading)
                    .padding(.trailing, BatteryCompactWarningLayout.cameraClearance)

                Color.clear.frame(width: cameraGap)

                HStack(spacing: 6) {
                    Text("\(batteryLevel)%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(BatteryCompactWarningLayout.minimumLabelScale)
                        .foregroundStyle(tint)
                    batteryIndicator.fixedSize()
                        .modifier(BatteryEventGlyphMotion(enabled: animateWarning, warning: true))
                }
                .frame(width: BatteryCompactWarningLayout.contentWidth, alignment: .trailing)
                .padding(.leading, BatteryCompactWarningLayout.cameraClearance)
            }
            .padding(.horizontal, BatteryCompactWarningLayout.outerPadding)
        } else {
            // Preserve the existing Charging and Full Battery compact rows.
            HStack {
                Text(verbatim: title)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                HStack(spacing: 6) {
                    Text("\(batteryLevel)%")
                        .font(.system(size: 14))
                        .foregroundColor(tint)
                    batteryIndicator
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var batteryIndicator: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.3))
                GeometryReader { geo in
                    let clamped = max(0, min(batteryLevel, 100))
                    let width = CGFloat(clamped) / 100 * geo.size.width
                    Rectangle()
                        .fill(tint.gradient)
                        .frame(width: max(0, width))
                }
            }
            .frame(width: 28, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(batteryLevel == 100 ? tint.gradient : tint.opacity(0.3).gradient)
                .frame(width: 2, height: 6)
        }
    }
}

/// Uses the Mac battery HUD shell and camera-safe compact row without changing them.
struct AirPodsLowBatteryActivityView: View {
    let reading: AirPodsBatteryReading
    let style: BatteryNotificationStyle
    let closedNotchWidth: CGFloat
    let baseHeight: CGFloat
    let isDynamicIslandMode: Bool
    let topCornerRadius: CGFloat

    private var surfaceShape: AnyShape {
        if isDynamicIslandMode {
            return AnyShape(DynamicIslandPillShape(cornerRadius: dynamicIslandPillCornerRadiusInsets.opened))
        }
        return AnyShape(NotchShape(topCornerRadius: topCornerRadius,
            bottomCornerRadius: style == .compact ? max(baseHeight / 2, 16) : 40))
    }
    var body: some View {
        let size = AirPodsBatteryWarningLayout.surface(closed: CGSize(width: closedNotchWidth, height: baseHeight), style: style)
        Group {
            if style == .compact {
                BatteryCompactStatusRow(title: reading.lowSide.compactTitle, batteryLevel: reading.listeningLevel ?? 0,
                    tint: .red, cameraGap: closedNotchWidth, animateWarning: true)
                    .frame(height: baseHeight)
            } else {
                VStack(spacing: 0) {
                    Color.clear.frame(height: baseHeight)
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(reading.lowSide.expandedTitle).foregroundStyle(.white.opacity(0.9))
                                Text("\(reading.listeningLevel ?? 0)%").foregroundStyle(.red)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.85)
                            Text(verbatim: reading.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1).truncationMode(.tail)
                            Text(verbatim: reading.detail)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: reading.symbol)
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 36).fixedSize()
                            .modifier(BatteryEventGlyphMotion(enabled: true, warning: true))
                    }
                    .padding(.horizontal, 32)
                    .frame(height: 75)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(surfaceShape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.name), \(reading.lowSide.expandedTitle), \(reading.detail)")
    }
}

struct BatteryTemporaryActivityView: View {
    let kind: BatteryTemporaryHUDKind
    let batteryLevel: Int
    let isLowPowerMode: Bool
    let closedNotchWidth: CGFloat
    let baseHeight: CGFloat
    let isDynamicIslandMode: Bool
    let topCornerRadius: CGFloat
    @Default(.lowBatteryHUDStyle) var lowBatteryHUDStyle
    @Default(.fullBatteryHUDStyle) var fullBatteryHUDStyle
    var styleOverride: BatteryNotificationStyle? = nil
    var isCriticalWarning: Bool = false

    @State private var pulse = false
    @State private var showBatteryIndicator = false
    @State private var changeBatteryIndicator = true
    @State private var connectorOffset: CGFloat = 0
    @State private var connectorOpacity: Double = 1

    private var style: BatteryNotificationStyle {
        BatteryTemporaryHUDPresentation.style(for: kind, lowWarningOverride: styleOverride,
            lowDefault: lowBatteryHUDStyle, fullDefault: fullBatteryHUDStyle)
    }

    private var metrics: BatteryTemporaryHUDMetrics {
        kind.metrics(
            style: style,
            closedNotchWidth: closedNotchWidth,
            baseHeight: baseHeight
        )
    }

    private var batteryTint: Color {
        if isCriticalWarning { return .red }
        switch kind {
        case .charging:
            if isLowPowerMode {
                return .yellow
            } else if batteryLevel <= 20 {
                return .red
            }
            return .green
        case .lowBattery:
            return isLowPowerMode ? .yellow : .red
        case .fullBattery:
            return isLowPowerMode ? .yellow : .green
        case .lowPowerEnabled:
            return .yellow
        case .lowPowerDisabled:
            return .white
        case .unplugged:
            return .white
        }
    }


    private var surfaceShape: AnyShape {
        if isDynamicIslandMode {
            return AnyShape(DynamicIslandPillShape(cornerRadius: dynamicIslandPillCornerRadiusInsets.opened))
        } else {
            return AnyShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: metrics.bottomRadius))
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
        }
        .frame(width: metrics.width, height: metrics.height, alignment: .bottom)
        .clipShape(surfaceShape)
        .onAppear(perform: prepareAnimations)
    }

    @ViewBuilder
    private var content: some View {
        if style == .compact {
            BatteryCompactStatusRow(
                title: compactTitle,
                batteryLevel: batteryLevel,
                tint: batteryTint,
                cameraGap: closedNotchWidth
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            VStack {
                Spacer()

                HStack {
                    VStack(alignment: .leading, spacing: kind == .lowBattery ? 2 : 3) {
                        standardTitle
                        standardDescription
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    Spacer()

                    standardIndicator
                        .fixedSize()
                }
                .padding(.leading, kind == .lowBattery ? 40 : 35)
                .padding(.trailing, kind == .lowBattery ? 45 : 40)
                .padding(.bottom, 20)
            }
        }
    }

    private var compactTitle: String {
        switch kind {
        case .charging:
            return String(localized: "Charging")
        case .lowBattery:
            return String(localized: "Low Battery")
        case .fullBattery:
            return String(localized: "Full Battery")
        case .lowPowerEnabled:
            return String(localized: "Low Power")
        case .lowPowerDisabled:
            return String(localized: "Normal")
        case .unplugged:
            return String(localized: "Unplugged")
        }
    }

    @ViewBuilder
    private var standardTitle: some View {
        HStack(spacing: 5) {
            Text(verbatim: standardTitleText)
                .font(.system(size: isCriticalWarning ? 16 : 13, weight: isCriticalWarning ? .bold : .semibold, design: .rounded))
                .foregroundStyle(isCriticalWarning ? .red : .white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text("\(batteryLevel)%")
                .font(.system(size: isCriticalWarning ? 16 : (kind == .lowBattery ? 12 : 13), weight: isCriticalWarning ? .bold : .semibold, design: .rounded))
                .foregroundStyle(batteryTint)
        }
    }

    private var standardTitleText: String {
        switch kind {
        case .charging: return String(localized: "Charging")
        case .lowBattery: return isCriticalWarning ? String(localized: "Battery Critical") : String(localized: "Battery Low")
        case .fullBattery: return String(localized: "Full Battery")
        case .lowPowerEnabled: return String(localized: "Low Power Mode")
        case .lowPowerDisabled: return String(localized: "Low Power Mode Off")
        case .unplugged: return String(localized: "Power Unplugged")
        }
    }

    @ViewBuilder
    private var standardDescription: some View {
        switch kind {
        case .charging:
            Text("Your Mac is connected to power.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        case .lowBattery:
            if isCriticalWarning {
                Text("Connect power now. Your Mac may shut down soon.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLowPowerMode {
                (
                    Text(verbatim: String(localized: "Low Power Mode enabled"))
                        .foregroundColor(.yellow)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    +
                    Text(verbatim: String(localized: ", it is recommended to charge it."))
                        .foregroundColor(.gray.opacity(0.6))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                )
            } else {
                Text(verbatim: String(localized: "Turn on Low Power Mode or it\nis recommended to charge it."))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.gray.opacity(0.6))
                    .lineLimit(2)
            }
        case .lowPowerEnabled:
            if batteryLevel <= Defaults[.lowBatteryHUDThreshold] {
                Text(verbatim: String(localized: "It is recommended to charge your Mac."))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.gray.opacity(0.72))
                    .lineLimit(1)
            }
        case .fullBattery:
            Text(verbatim: String(localized: "Your Mac is fully charged."))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.gray.opacity(0.6))
                .fontWeight(.medium)
                .lineLimit(1)
        case .lowPowerDisabled:
            Text(verbatim: String(localized: "Normal battery performance."))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.gray.opacity(0.72))
                .lineLimit(1)
        case .unplugged:
            Text(verbatim: String(localized: "Your Mac is now running on battery power."))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.gray.opacity(0.72))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var standardIndicator: some View {
        switch kind {
        case .charging:
            magSafeIndicator
        case .lowBattery:
            if isLowPowerMode {
                yellowLowIndicator
            } else {
                redLowIndicator
            }
        case .fullBattery:
            if showBatteryIndicator {
                if isLowPowerMode {
                    yellowFullIndicator
                        .transition(.opacity.combined(with: .scale))
                } else {
                    greenFullIndicator
                        .transition(.opacity.combined(with: .scale))
                }
            } else {
                magSafeIndicator
                    .transition(.opacity.combined(with: .scale))
            }
        case .lowPowerEnabled:
            yellowLowIndicator
        case .lowPowerDisabled:
            lowPowerDisabledIndicator
        case .unplugged:
            unpluggedIndicator
        }
    }

    private var redLowIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.red.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.4))
                    .frame(width: 40, height: 24)

                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
            .padding(.trailing, 5)

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.gradient)
                .frame(width: 8, height: 14)
                .opacity(pulse ? 1 : 0.3)
                .offset(x: -15)

            RoundedRectangle(cornerRadius: 30)
                .stroke(Color.red.opacity(0.9), lineWidth: 1.5)
                .frame(width: pulse ? 8 : 30, height: pulse ? 14 : 32)
                .offset(x: -15)
                .opacity(pulse ? 0.3 : 1)
        }
    }

    private var yellowLowIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.yellow.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 40, height: 24)

                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
            .padding(.trailing, 5)

            RoundedRectangle(cornerRadius: 8)
                .fill(.yellow.gradient)
                .frame(width: 8, height: 14)
                .offset(x: -15)
                .opacity(pulse ? 1 : 0.45)
        }
    }

    private var greenFullIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.green.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.green.opacity(0.4))
                    .frame(width: 44, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.gradient)
                            .frame(width: 34, height: 14)
                            .opacity(pulse ? 1 : 0.4)
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(.green.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
        }
    }

    private var yellowFullIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.yellow.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 44, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.yellow.gradient)
                            .frame(width: 34, height: 14)
                            .opacity(pulse ? 1 : 0.4)
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
        }
    }

    private var magSafeIndicator: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.gray.opacity(0.15))
                .frame(width: 30, height: 5)

            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.gray.opacity(0.2).gradient)
                    .frame(width: 30, height: 40)

                Circle()
                    .fill(changeBatteryIndicator ? .orange : .green)
                    .shadow(color: changeBatteryIndicator ? .orange : .green, radius: 5)
                    .frame(width: 5, height: 5)
            }

            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 3, height: 32)
        }
    }

    private var lowPowerDisabledIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 44, height: 24)
                    .overlay {
                        Image(systemName: "bolt.slash.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(changeBatteryIndicator ? Color.yellow : Color.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.38))
                    .frame(width: 3, height: 8)
            }
        }
    }

    private var unpluggedIndicator: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.gray.opacity(0.15))
                .frame(width: 30, height: 5)

            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.gray.opacity(0.2).gradient)
                    .frame(width: 30, height: 40)
                Circle()
                    .fill(.white)
                    .shadow(color: .white.opacity(0.8), radius: 4)
                    .frame(width: 5, height: 5)
            }
            .offset(x: connectorOffset)
            .opacity(connectorOpacity)

            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 3, height: 32)
        }
    }

    private func prepareAnimations() {
        pulse = false
        showBatteryIndicator = kind == .fullBattery && style == .standard
        changeBatteryIndicator = true
        connectorOffset = 0
        connectorOpacity = 1

        guard style == .standard else { return }

        switch kind {
        case .charging:
            break
        case .lowBattery:
            if !isLowPowerMode {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        case .fullBattery:
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.spring(duration: 0.4)) {
                    showBatteryIndicator = false
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.spring(duration: 0.2)) {
                    changeBatteryIndicator = false
                }
            }
        case .lowPowerEnabled:
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        case .lowPowerDisabled:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    changeBatteryIndicator = false
                }
            }
        case .unplugged:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    connectorOffset = -18
                    connectorOpacity = 0
                }
            }
        }
    }
}

#Preview {
    DynamicIslandBatteryView(
        batteryWidth: 30,
        isCharging: false,
        isInLowPowerMode: false,
        isPluggedIn: true,
        levelBattery: 80,
        maxCapacity: 100,
        timeToFullCharge: 10,
        timeToEmpty: 0,
        isForNotification: false
    ).frame(width: 200, height: 200)
}

/// Animates accessory artwork inside its reserved frame, never the notch shell.
struct BatteryEventGlyphMotion: ViewModifier {
    var enabled: Bool
    var warning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var pulse = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(!enabled || reduceMotion || appeared ? 1 : 0.84)
            .opacity(enabled && !reduceMotion && warning && pulse ? 0.65 : 1)
            .onAppear {
                guard enabled, !reduceMotion else { appeared = true; return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { appeared = true }
                if warning {
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
                }
            }
    }
}
