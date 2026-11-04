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

import CoreGraphics

enum RecordingHUDPresentation: String, CaseIterable {
    case compact
    case inline
    case expanded

    var extraWidth: CGFloat {
        switch self {
        case .compact:
            return 132
        case .inline:
            return 176
        case .expanded:
            return 140
        }
    }

    var extraHeight: CGFloat {
        self == .expanded ? 70 : 0
    }

    /// A closed recording HUD straddles the physical notch. Equal wings keep
    /// its center exclusion exactly over the camera housing.
    var wingWidth: CGFloat {
        extraWidth / 2
    }
}

struct RecordingHUDLayout {
    let isVisible: Bool
    let stopControlsEnabled: Bool
    let hoverStyle: RecordingHoverStyle
    let expanded: Bool
    let suppressHoverExpansion: Bool

    var presentation: RecordingHUDPresentation {
        guard isVisible else { return .compact }
        guard !suppressHoverExpansion else { return .compact }
        guard stopControlsEnabled && expanded else { return .compact }

        switch hoverStyle {
        case .default:
            return .expanded
        case .inline:
            return .inline
        }
    }

    var showsDefaultExpansion: Bool {
        isVisible && presentation == .expanded
    }

    var showsInlineExpansion: Bool {
        isVisible && presentation == .inline
    }

    var extraWidth: CGFloat {
        isVisible ? presentation.extraWidth : 0
    }

    var extraHeight: CGFloat {
        isVisible ? presentation.extraHeight : 0
    }

    func size(closedNotchSize: CGSize, effectiveClosedNotchHeight: CGFloat) -> CGSize? {
        guard isVisible else { return nil }

        return CGSize(
            width: closedNotchSize.width + extraWidth,
            height: effectiveClosedNotchHeight + extraHeight
        )
    }

    /// A foreground control or battery toast owns the closed-notch window.
    /// The recording HUD remains active underneath, but must not size it.
    func sizeWhenFrontmost(
        closedNotchSize: CGSize,
        effectiveClosedNotchHeight: CGFloat,
        sneakPeekVisible: Bool,
        competingExpansionVisible: Bool
    ) -> CGSize? {
        guard !sneakPeekVisible, !competingExpansionVisible else { return nil }
        return size(
            closedNotchSize: closedNotchSize,
            effectiveClosedNotchHeight: effectiveClosedNotchHeight
        )
    }
}

func makeRecordingHUDLayout(
    notchState: NotchState,
    screenRecordingDetectionEnabled: Bool,
    showRecordingIndicator: Bool,
    hideOnClosed: Bool,
    isRecording: Bool,
    closedMusicPairingEligible: Bool,
    recordingControlMode: RecordingControlMode,
    canStopFromHUD: Bool,
    recordingHoverStyle: RecordingHoverStyle,
    suppressHoverExpansion: Bool = false,
    expanded: Bool,
    foregroundTimerActive: Bool = false
) -> RecordingHUDLayout {
    let isVisible = notchState == .closed
        && screenRecordingDetectionEnabled
        && showRecordingIndicator
        && !hideOnClosed
        && isRecording
        && !closedMusicPairingEligible
        && !foregroundTimerActive

    let stopControlsEnabled = recordingControlMode == .withStopButton
        && canStopFromHUD

    return RecordingHUDLayout(
        isVisible: isVisible,
        stopControlsEnabled: stopControlsEnabled,
        hoverStyle: recordingHoverStyle,
        expanded: expanded,
        suppressHoverExpansion: suppressHoverExpansion
    )
}

/// Recording's local controls must not expand before the ordinary hover-open.
/// Click-to-open users retain their chosen recording control presentation.
func suppressRecordingHoverExpansion(screenSharingAppActive: Bool, opensNotchOnHover: Bool) -> Bool {
    screenSharingAppActive || opensNotchOnHover
}

/// Transparent layout space only; the visible closed HUD keeps its own size.
func recordingTransitionCanvas(surface: CGSize, opened: CGSize) -> CGSize {
    CGSize(width: max(surface.width, opened.width), height: max(surface.height, opened.height))
}
