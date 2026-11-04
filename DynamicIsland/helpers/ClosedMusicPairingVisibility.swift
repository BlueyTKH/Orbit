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

/// Paused-track metadata remains eligible for the ordinary closed music view.
/// During a visible recording, only actual playback should take priority:
/// otherwise a stale non-idle snapshot briefly replaces the recording HUD.
func hasActiveClosedMusicSnapshot(
    isPlaying: Bool,
    isPlayerIdle: Bool,
    hasMusicMetadata: Bool,
    recordingIndicatorVisible: Bool
) -> Bool {
    if isPlaying { return true }
    if recordingIndicatorVisible { return false }
    return !isPlayerIdle && hasMusicMetadata
}

func isClosedMusicPairingEligible(
    notchState: NotchState,
    hasActiveMusicSnapshot: Bool,
    musicLiveActivityEnabled: Bool,
    closedMusicContentEnabled: Bool,
    hideOnClosed: Bool,
    isLocked: Bool,
    isDeferredAfterUnlock: Bool
) -> Bool {
    notchState == .closed
        && hasActiveMusicSnapshot
        && musicLiveActivityEnabled
        && closedMusicContentEnabled
        && !hideOnClosed
        && !isLocked
        && !isDeferredAfterUnlock
}
