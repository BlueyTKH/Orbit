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

import SwiftUI
import AppKit
import Defaults

struct AirPodsListeningModeSymbol: View {
    let mode: AirPodsListeningMode
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: mode.sfSymbol)
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect)
            .frame(width: size + 2, height: size + 2)
    }
}

struct InlineHUD: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Binding var hoverAnimation: Bool
    @Binding var gestureProgress: CGFloat
    
    @Default(.useColorCodedBatteryDisplay) var useColorCodedBatteryDisplay
    @Default(.useColorCodedVolumeDisplay) var useColorCodedVolumeDisplay
    @Default(.useSmoothColorGradient) var useSmoothColorGradient
    @Default(.progressBarStyle) var progressBarStyle
    @Default(.useCircularBluetoothBatteryIndicator) var useCircularBluetoothBatteryIndicator
    @Default(.showBluetoothBatteryPercentageText) var showBluetoothBatteryPercentageText
    @Default(.showBluetoothDeviceNameMarquee) var showBluetoothDeviceNameMarquee
    @Default(.showCapsLockLabel) var showCapsLockLabel
    @Default(.capsLockIndicatorTintMode) var capsLockTintMode
    @ObservedObject var bluetoothManager = BluetoothAudioManager.shared
    
    @State private var displayName: String = ""

    static func airPodsListeningModeWidth(
        closedNotchWidth: CGFloat,
        gestureProgress: CGFloat
    ) -> CGFloat {
        let leadingWidth: CGFloat = 44
        let trailingWidth: CGFloat = 180
        let centerWidth = max(closedNotchWidth - 20, 0)
        return leadingWidth + trailingWidth + centerWidth + gestureProgress
    }

    static func safeWingWidth(
        leadingWidth: CGFloat,
        centerWidth: CGFloat,
        trailingWidth: CGFloat,
        physicalWidth: CGFloat
    ) -> CGFloat {
        max(0, (leadingWidth + centerWidth + trailingWidth - physicalWidth) / 2)
    }

    static func capsLockGlyphInset(
        leadingWidth: CGFloat,
        centerWidth: CGFloat,
        trailingWidth: CGFloat,
        physicalWidth: CGFloat
    ) -> CGFloat {
        let surfaceWidth = leadingWidth + centerWidth + trailingWidth + 16 // two 8pt HStack gaps
        let cameraWidth = max(centerWidth, physicalWidth)
        let visibleLeftWing = max(0, (surfaceWidth - cameraWidth) / 2)
        return min(12, max(0, visibleLeftWing - 20 - 4)) // glyph width + camera clearance
    }
    
    var body: some View {
        let useCircularIndicator = useCircularBluetoothBatteryIndicator
        let listeningModeEvent = bluetoothManager.activeListeningModeEvent
        let listeningMode = listeningModeEvent?.mode ?? (type == .bluetoothAudio && value == -1 ? AirPodsListeningMode.fromHUDSymbol(icon) : nil)
        let isListeningModeEvent = type == .bluetoothAudio && listeningMode != nil
        let hasBatteryLevel = value >= 0 && !isListeningModeEvent
        let capsLockAccentColor = capsLockTintMode.color

        // Widths stay constant whether hovered or not so HUD text/icons do
        // not slide toward the notch edges when the user moves over it.
        let baseInfoWidth: CGFloat = {
            if type == .bluetoothAudio {
                if isListeningModeEvent {
                    return 44
                }
                if showBluetoothDeviceNameMarquee {
                    return 132
                }
                return 64
            }

            if type == .capsLock && !showCapsLockLabel {
                return 56
            }

            return 92
        }()

        let infoWidth: CGFloat = {
            let width = baseInfoWidth + gestureProgress / 2
            let minimum: CGFloat = {
                if type == .bluetoothAudio {
                    if isListeningModeEvent {
                        return 38
                    }
                    if showBluetoothDeviceNameMarquee {
                        return 112
                    }
                    return 60
                }

                if type == .capsLock && !showCapsLockLabel {
                    return 44
                }

                return 88
            }()
            return max(width, minimum)
        }()

        let baseTrailingWidth: CGFloat = {
            if type == .bluetoothAudio {
                if !hasBatteryLevel {
                    if isListeningModeEvent {
                        return 180
                    }
                    return showBluetoothDeviceNameMarquee ? 110 : 80
                }

                if useCircularIndicator {
                    return showBluetoothBatteryPercentageText ? 112 : 76
                }

                return showBluetoothBatteryPercentageText ? 128 : 100
            }

            if type == .capsLock {
                if showCapsLockLabel {
                    return 88
                }
                return 0
            }

            return 92
        }()

        let trailingWidth: CGFloat = {
            let width = baseTrailingWidth + gestureProgress / 2
            let minimum: CGFloat = {
                if type == .bluetoothAudio {
                    if !hasBatteryLevel {
                        if isListeningModeEvent {
                            return 172
                        }
                        return showBluetoothDeviceNameMarquee ? 102 : 80
                    }

                    if useCircularIndicator {
                        return showBluetoothBatteryPercentageText ? 102 : 64
                    }

                    return showBluetoothBatteryPercentageText ? 112 : 82
                }

                if type == .capsLock {
                    return showCapsLockLabel ? 72 : 0
                }

                return 90
            }()
            return max(width, minimum)
        }()

        // Bluetooth labels need explicit camera clearance. Keep the original
        // full-width system-control geometry; applying this limit to volume or
        // brightness shortens their progress bars and the whole HUD.
        let isBluetoothHUD = type == .bluetoothAudio
        let physicalWidth: CGFloat = {
            let selectedScreen = vm.screen.flatMap { name in
                NSScreen.screens.first(where: { $0.localizedName == name })
            } ?? NSScreen.main
            return selectedScreen.flatMap { PhysicalNotchLayout.measuredWidth(for: $0) } ?? 0
        }()
        let centerWidth = isBluetoothHUD
            ? max(vm.closedNotchSize.width - 20, 0)
            : vm.closedNotchSize.width
        let visibleWingWidth = Self.safeWingWidth(
            leadingWidth: infoWidth,
            centerWidth: centerWidth,
            trailingWidth: trailingWidth,
            physicalWidth: physicalWidth
        )
        let safeLeadingWidth = isBluetoothHUD ? min(infoWidth, visibleWingWidth) : infoWidth
        let safeTrailingWidth = isBluetoothHUD ? min(trailingWidth, visibleWingWidth) : trailingWidth
        let capsLockInset = type == .capsLock && !showCapsLockLabel
            ? Self.capsLockGlyphInset(
                leadingWidth: infoWidth,
                centerWidth: centerWidth,
                trailingWidth: trailingWidth,
                physicalWidth: physicalWidth
            )
            : 0

        return HStack(spacing: isBluetoothHUD ? 0 : 8) {
            HStack(spacing: 5) {
                Group {
                    switch (type) {
                        case .volume:
                            if icon.isEmpty {
                                // Show headphone icon if Bluetooth audio is connected, otherwise speaker
                                let baseIcon = bluetoothManager.isBluetoothAudioConnected ? "headphones" : SpeakerSymbol(value)
                                Image(systemName: baseIcon)
                                    .contentTransition(.interpolate)
                                    .symbolVariant(value > 0 ? .none : .slash)
                                    .frame(width: 20, height: 15, alignment: .leading)
                            } else {
                                Image(systemName: icon)
                                    .contentTransition(.interpolate)
                                    .opacity(value.isZero ? 0.6 : 1)
                                    .scaleEffect(value.isZero ? 0.85 : 1)
                                    .frame(width: 20, height: 15, alignment: .leading)
                            }
                        case .brightness:
                            Image(systemName: !icon.isEmpty ? icon : BrightnessSymbol(value))
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .backlight:
                            Image(systemName: BacklightSymbol(value))
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .mic:
                            Image(systemName: "mic")
                                .symbolRenderingMode(.hierarchical)
                                .symbolVariant(value > 0 ? .none : .slash)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .timer:
                            Image(systemName: "timer")
                                .symbolRenderingMode(.hierarchical)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .bluetoothAudio:
                            if let listeningMode {
                                AirPodsListeningModeSymbol(mode: listeningMode)
                                    .contentTransition(.interpolate)
                                    .frame(width: 20, height: 15, alignment: .center)
                            } else {
                                Image(systemName: icon.isEmpty ? "dot.radiowaves.left.and.right" : icon)
                                    .symbolRenderingMode(.hierarchical)
                                    .contentTransition(.interpolate)
                                    .frame(width: 20, height: 15, alignment: .center)
                            }
                        case .capsLock:
                            Image(systemName: "capslock.fill")
                                .symbolRenderingMode(.hierarchical)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                                // Clear the rounded end, but stay outside the
                                // measured camera housing on this display.
                                .offset(x: capsLockInset)
                                .foregroundStyle(capsLockAccentColor)
                        default:
                            EmptyView()
                    }
                }
                .foregroundStyle(.white)
                .symbolVariant(.fill)
                
                // Use marquee text for device names to handle long names
                if type == .bluetoothAudio {
                    if isListeningModeEvent {
                        EmptyView()
                    } else if showBluetoothDeviceNameMarquee {
                        MarqueeText(
                            $displayName,
                            font: .system(size: 13, weight: .medium),
                            nsFont: .body,
                            textColor: .white,
                            minDuration: 0.2,
                            frameWidth: max(0, safeLeadingWidth - 25)
                        )
                    }
                } else if type != .capsLock {
                    Text(Type2Name(type))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: safeLeadingWidth, height: vm.notchSize.height - 12, alignment: .leading)
            .frame(width: infoWidth, alignment: .leading)
            
            Rectangle()
                .fill(.black)
                .frame(width: centerWidth)
            
            HStack {
                if (type == .mic) {
                    Text(value.isZero ? "muted" : "unmuted")
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                } else if (type == .timer) {
                    Text(TimerManager.shared.formattedRemainingTime())
                        .foregroundStyle(TimerManager.shared.timerColor)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                } else if (type == .capsLock) {
                    if showCapsLockLabel {
                        Text("Caps Lock")
                            .foregroundStyle(capsLockAccentColor)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .allowsTightening(true)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .contentTransition(.interpolate)
                    }
                } else if (type == .bluetoothAudio) {
                    if let listeningMode {
                        let listeningModeTextWidth: CGFloat = 124

                        // Render every mode label with a trailing-aligned Text.
                        // The previous MarqueeText path is `.leading`-aligned
                        // internally, so the longer modes (Noise Cancellation /
                        // Adaptive Audio / Conversation Awareness) hugged the notch
                        // edge and were clipped behind it — only the short,
                        // trailing-aligned modes (Transparency / Off) stayed
                        // visible. A scaling Text keeps every mode on screen.
                        Text(listeningMode.displayName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .truncationMode(.tail)
                            .allowsTightening(true)
                            .frame(
                                width: min(max(trailingWidth - 44, 64), listeningModeTextWidth, safeTrailingWidth),
                                alignment: .trailing
                            )
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else if hasBatteryLevel {
                        let indicatorSpacing: CGFloat = {
                            if useCircularIndicator {
                                return showBluetoothBatteryPercentageText ? 8 : 2
                            }
                            return showBluetoothBatteryPercentageText ? 6 : 4
                        }()

                        HStack(spacing: indicatorSpacing) {
                            if useCircularIndicator {
                                DeviceBatteryRing(
                                    value: value,
                                    useColorCoding: useColorCodedBatteryDisplay && progressBarStyle != .segmented,
                                    smoothGradient: useSmoothColorGradient,
                                    diameter: bluetoothManager.lastConnectedDevice?.deviceType.isAirPods == true ? 16 : 20,
                                    symbol: bluetoothManager.lastConnectedDevice?.deviceType.isAirPods == true ? nil : icon
                                )
                                .allowsHitTesting(false)
                            } else {
                                LinearBatteryIndicator(
                                    value: value,
                                    useColorCoding: useColorCodedBatteryDisplay && progressBarStyle != .segmented,
                                    smoothGradient: useSmoothColorGradient
                                )
                                .allowsHitTesting(false)
                            }

                            if showBluetoothBatteryPercentageText {
                                Text("\(Int(value * 100))%")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    // Volume and brightness displays
                    Group {
                        HStack(spacing: 6) {
                            DraggableProgressBar(
                                value: $value,
                                colorMode: type == .volume ? .volume : nil
                            )
                            // System control HUDs always show their numeric
                            // level, including volume at zero. This preserves
                            // Atoll's layout while removing the inconsistent
                            // preference-dependent label.
                            PercentageLabel(value: value, isVisible: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.trailing, trailingWidth > 0 ? 4 : 0)
            .frame(width: safeTrailingWidth, height: vm.closedNotchSize.height - 12, alignment: .trailing)
            .frame(width: trailingWidth, alignment: .trailing)
        }
        .frame(height: vm.closedNotchSize.height, alignment: .center)
        .onAppear {
            displayName = Type2Name(type)
        }
        .onChange(of: type) { _, _ in
            displayName = Type2Name(type)
        }
        .onChange(of: bluetoothManager.lastConnectedDevice?.name) { _, _ in
            displayName = Type2Name(type)
        }
    }
    
    private struct LinearBatteryIndicator: View {
        let value: CGFloat
        let useColorCoding: Bool
        let smoothGradient: Bool

        private let trackWidth: CGFloat = 54
        private let trackHeight: CGFloat = 6

        private var clampedValue: CGFloat {
            min(max(value, 0), 1)
        }

        private var fillColor: Color {
            if useColorCoding {
                return ColorCodedProgressBar.paletteColor(for: clampedValue, mode: .battery, smoothGradient: smoothGradient)
            }
            return .white
        }

        var body: some View {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: trackWidth, height: trackHeight)

                Capsule()
                    .fill(fillColor)
                    .frame(width: trackWidth * clampedValue, height: trackHeight)
            }
            .frame(width: trackWidth, height: trackHeight)
            .animation(.smooth(duration: 0.18), value: clampedValue)
        }
    }

    func SpeakerSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0:
                return "speaker"
            case 0...0.3:
                return "speaker.wave.1"
            case 0.3...0.8:
                return "speaker.wave.2"
            case 0.8...1:
                return "speaker.wave.3"
            default:
                return "speaker.wave.2"
        }
    }
    
    func BrightnessSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0...0.6:
                return "sun.min"
            case 0.6...1:
                return "sun.max"
            default:
                return "sun.min"
        }
    }

    func BacklightSymbol(_ value: CGFloat) -> String {
        if value >= 0.5 {
            return "light.max"
        }
        return "light.min"
    }
    
    func Type2Name(_ type: SneakContentType) -> String {
        switch(type) {
            case .volume:
                return String(localized: "Volume")
            case .brightness:
                return String(localized: "Brightness")
            case .backlight:
                return String(localized: "Backlight")
            case .mic:
                return String(localized: "Mic")
            case .bluetoothAudio:
                return BluetoothAudioManager.shared.lastConnectedDevice?.name ?? "Bluetooth"
            case .capsLock:
                return String(localized: "Caps Lock")
            default:
                return ""
        }
    }
}

#Preview {
    InlineHUD(type: .constant(.brightness), value: .constant(0.4), icon: .constant(""), hoverAnimation: .constant(false), gestureProgress: .constant(0))
        .padding(.horizontal, 8)
        .background(Color.black)
        .padding()
        .environmentObject(DynamicIslandViewModel())
}
