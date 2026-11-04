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

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

/// Keeps expanded-notch header content outside the physical camera housing.
/// The user-configurable closed notch can be narrower than the real hardware,
/// but controls in the header must reserve the real dead space on displays
/// that have a physical notch.
enum NotchHeaderLayout {
    static func deadSpaceWidth(
        configuredWidth: CGFloat,
        physicalWidth: CGFloat?,
        hasPhysicalNotch: Bool
    ) -> CGFloat {
        let configuredWidth = max(0, configuredWidth)
        guard hasPhysicalNotch, let physicalWidth, physicalWidth > 0 else {
            return configuredWidth
        }
        return max(configuredWidth, physicalWidth)
    }
}

/// The hardware camera housing is a hard layout boundary. A user preference
/// may make the rendered notch wider, but must never make its content lane
/// narrower than the cutout reported by macOS.
enum PhysicalNotchLayout {
    static func safeWidth(configuredWidth: CGFloat, measuredWidth: CGFloat?) -> CGFloat {
        max(0, max(configuredWidth, measuredWidth ?? 0))
    }

    static func measuredWidth(for screen: NSScreen) -> CGFloat? {
        guard screen.safeAreaInsets.top > 0,
              let leftWidth = screen.auxiliaryTopLeftArea?.width,
              let rightWidth = screen.auxiliaryTopRightArea?.width else {
            return nil
        }
        return max(0, screen.frame.width - leftWidth - rightWidth)
    }
}

/// Layout budgets applied to the home view only while the side lyrics panel is active
enum SideLyricsLayout {
    /// Room the standard player needs for its album art and five-button control row
    static let minimumPlayerWidth: CGFloat = 380

    /// Room the webcam mirror needs to stay usable next to the player
    static let minimumMirrorWidth: CGFloat = 220

    /// Spacing between the player, mirror, and lyrics panel columns
    static let hStackSpacing: CGFloat = 20

    /// Combined home-view and notch content insets surrounding those columns
    static let combinedInset: CGFloat = 40
}

func sideLyricsRequiredNotchWidth() -> CGFloat {
    guard Defaults[.enableLyrics],
          !Defaults[.showCalendar],
          Defaults[.showStandardMediaControls],
          (!Defaults[.autoHideInactiveNotchMediaPlayer] || MusicManager.shared.hasActiveSession)
    else { return 0 }

    let panelWidth = max(0, Defaults[.lyricsPanelWidth])
    let offsetDistance = abs(Defaults[.lyricsPanelOffset])
    let mirrorWidth = Defaults[.showMirror] && WebcamManager.shared.cameraAvailable
        ? SideLyricsLayout.minimumMirrorWidth + SideLyricsLayout.hStackSpacing
        : 0

    // Include the home-view and notch content insets so the player receives
    // the same usable width it had before the panel was added.
    return SideLyricsLayout.minimumPlayerWidth
        + panelWidth
        + SideLyricsLayout.hStackSpacing
        + offsetDistance
        + mirrorWidth
        + SideLyricsLayout.combinedInset
}

var openNotchSize: CGSize {
    let storedWidth = Defaults[.openNotchWidth]
    let minWidth = currentRecommendedMinimumNotchWidth()
    let maxWidth = maxAllowedNotchWidth()
    let width = min(max(storedWidth, minWidth, sideLyricsRequiredNotchWidth()), maxWidth)
    return .init(width: width, height: 200)
}

/// Maximum notch width based on the current screen's point width.
/// Prevents the notch from extending beyond the screen on scaled displays.
func maxAllowedNotchWidth(for screenName: String? = nil) -> CGFloat {
    let screen: NSScreen?
    if let screenName {
        screen = NSScreen.screens.first { $0.localizedName == screenName }
    } else {
        screen = NSScreen.main
    }
    guard let screenWidth = screen?.frame.width, screenWidth > 0 else {
        return 900
    }
    return max(screenWidth - 60, 400)
}

/// Convenience for the main screen.
func maxAllowedNotchWidth() -> CGFloat {
    maxAllowedNotchWidth(for: nil)
}

// MARK: - Tab-Based Notch Width

/// Counts the number of currently enabled standard notch tabs.
/// Mirrors the tab-building logic in ``TabSelectionView``.
func enabledStandardTabCount() -> Int {
    var count = 0

    // Home tab
    if Defaults[.showStandardMediaControls] || Defaults[.showCalendar] || Defaults[.showMirror] {
        count += 1
    }

    // Shelf tab
    if Defaults[.dynamicShelf] {
        count += 1
    }

    // Timer tab (only in .tab display mode)
    if Defaults[.enableTimerFeature] && Defaults[.timerDisplayMode] == .tab {
        count += 1
    }

    // Stats tab
    if Defaults[.enableStatsFeature] {
        count += 1
    }

    // Notes / Clipboard tab
    if Defaults[.enableNotes] || (Defaults[.enableClipboardManager] && Defaults[.clipboardDisplayMode] == .separateTab) {
        count += 1
    }

    return count
}

/// Returns the recommended minimum notch width for the given tab count.
func recommendedMinimumNotchWidth(forTabCount count: Int) -> CGFloat {
    if count >= 6 { return 770 }
    if count >= 5 { return 690 }
    return 640
}

/// Returns the recommended minimum notch width for the current tab configuration.
func currentRecommendedMinimumNotchWidth() -> CGFloat {
    recommendedMinimumNotchWidth(forTabCount: enabledStandardTabCount())
}

/// Enforces the minimum notch width based on current tab count.
/// Also clamps to screen width so the notch never exceeds the display.
func enforceMinimumNotchWidth() {
    let minWidth = currentRecommendedMinimumNotchWidth()
    let maxWidth = maxAllowedNotchWidth()
    var width = Defaults[.openNotchWidth]
    if width < minWidth { width = minWidth }
    if width > maxWidth { width = maxWidth }
    if Defaults[.openNotchWidth] != width {
        Defaults[.openNotchWidth] = width
    }
}
let statsSecondRowContentHeight: CGFloat = 120
let statsGridSpacingHeight: CGFloat = 12
let notchShadowPaddingStandard: CGFloat = 18
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 21, bottom: 27), closed: (top: 7, bottom: 16))

/// Height of the inline lyrics line shown under the artist name on the home tab.
///
/// The player column is laid out inside a greedy `GeometryReader`, so the lyrics
/// line takes its space out of the gap above the transport controls instead of
/// growing the notch. Handing that height back keeps the controls from being
/// crowded when lyrics are on.
let inlineLyricsLineHeight: CGFloat = 18

/// Grows the open notch by one lyrics line when the home tab renders inline lyrics.
///
/// The extra height is applied whenever inline lyrics are enabled rather than only
/// while a line is on screen, so the notch keeps a stable height between lyric lines.
///
func inlineLyricsAdjustedNotchSize(
    from baseSize: CGSize,
    isHomeTabActive: Bool
) -> CGSize {
    // The same conditions `sideLyricsRequiredNotchWidth` tests, for the same
    // reason: the extra line belongs to the standard player, so it is only
    // owed when that player is on screen to draw it. Without the last two the
    // notch grew for a line nobody could see whenever the player was switched
    // off, or hidden by auto-hide with nothing playing.
    guard isHomeTabActive,
          Defaults[.enableLyrics],
          Defaults[.showCalendar],
          Defaults[.showStandardMediaControls],
          (!Defaults[.autoHideInactiveNotchMediaPlayer] || MusicManager.shared.hasActiveSession)
    else {
        return baseSize
    }

    var adjustedSize = baseSize
    adjustedSize.height += inlineLyricsLineHeight
    return adjustedSize
}

func statsAdjustedNotchSize(
    from baseSize: CGSize,
    isStatsTabActive: Bool,
    secondRowProgress: CGFloat
) -> CGSize {
    guard isStatsTabActive, Defaults[.enableStatsFeature] else {
        return baseSize
    }

    let enabledGraphsCount = [
        Defaults[.showCpuGraph],
        Defaults[.showMemoryGraph],
        Defaults[.showGpuGraph],
        Defaults[.showNetworkGraph],
        Defaults[.showDiskGraph],
        Defaults[.showBatteryGraph] && BatteryHistoryManager.batterySupported
    ].filter { $0 }.count

    guard enabledGraphsCount >= 4 else {
        return baseSize
    }

    let clampedProgress = max(0, min(secondRowProgress, 1))
    guard clampedProgress > 0 else {
        return baseSize
    }

    var adjustedSize = baseSize
    let extraHeight = (statsSecondRowContentHeight + statsGridSpacingHeight) * clampedProgress
    adjustedSize.height += extraHeight
    return adjustedSize
}

func notchShadowPaddingValue() -> CGFloat {
    notchShadowPaddingStandard
}

func addShadowPadding(to size: CGSize) -> CGSize {
    CGSize(width: size.width, height: size.height + notchShadowPaddingValue())
}

/// Determines whether a specific screen should render the Dynamic Island pill
/// shape instead of the standard notch shape.
///
/// Returns `true` only when ALL of these conditions are met:
/// 1. The user has selected `.dynamicIsland` in `externalDisplayStyle`
/// 2. The screen does NOT have a physical notch (safeAreaInsets.top == 0)
///
/// Screens with a physical notch always use the standard notch shape.
func shouldUseDynamicIslandMode(for screenName: String?) -> Bool {
    guard Defaults[.externalDisplayStyle] == .dynamicIsland else {
        return false
    }

    var selectedScreen: NSScreen? = NSScreen.main
    if let screenName {
        selectedScreen = NSScreen.screens.first(where: { $0.localizedName == screenName })
    }

    guard let screen = selectedScreen else {
        // No screen found — fallback to standard notch
        return false
    }

    // Physical notch screens always use standard notch shape
    return screen.safeAreaInsets.top <= 0
}

/// Corner radius insets for the Dynamic Island pill shape.
/// - closed: half the closed notch height for a true capsule look
/// - opened: generous radius for smooth expanded pill
let dynamicIslandPillCornerRadiusInsets: (opened: CGFloat, closed: CGFloat) = (
    opened: 27,
    closed: 16
)

/// Extra window height past `screen.maxY` on physical-notch displays.
let notchTopScreenBleedAmount: CGFloat = 4

func notchTopScreenBleed(for screenName: String?) -> CGFloat {
    shouldUseDynamicIslandMode(for: screenName) ? 0 : notchTopScreenBleedAmount
}

/// Vertical offset from the top screen edge for the Dynamic Island pill.
/// Creates a visual gap so the pill floats below the menu bar, mimicking
/// the iPhone's Dynamic Island detachment from the physical screen edge.
let dynamicIslandTopOffset: CGFloat = 6

/// Extra horizontal padding applied OUTSIDE the pill clip shape in Dynamic
/// Island mode so the drop shadow has room to render without being clipped
/// by the outer frame constraint.
let dynamicIslandShadowInset: CGFloat = 14

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

func getScreenFrame(_ screen: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let customScreen = screen {
        selectedScreen = NSScreen.screens.first(where: { $0.localizedName == customScreen })
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

func getClosedNotchSize(screen: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = Defaults[.closedNotchWidth]

    var selectedScreen = NSScreen.main

    if let customScreen = screen {
        selectedScreen = NSScreen.screens.first(where: { $0.localizedName == customScreen })
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let measuredWidth = PhysicalNotchLayout.measuredWidth(for: screen) {
            let configuredWidth = Defaults[.customizePhysicalNotchWidth]
                ? Defaults[.closedNotchWidth]
                : measuredWidth
            notchWidth = PhysicalNotchLayout.safeWidth(
                configuredWidth: configuredWidth,
                measuredWidth: measuredWidth
            )
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
