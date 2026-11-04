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

struct DownloadLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @State private var downloadManager = DownloadManager.shared
    
    @State private var isHovering: Bool = false
    @State private var gestureProgress: CGFloat = 0
    @State private var isExpanded: Bool = false

    @Default(.selectedDownloadIndicatorStyle) private var indicatorStyle
    
    private var tint: Color {
        .accentColor
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Left side: download icon capsule
            Color.clear
                .background {
                    if isExpanded {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(tint.opacity(0.14))
                                
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(tint)
                            }
                            .frame(
                                width: vm.effectiveClosedNotchHeight - 12,
                                height: vm.effectiveClosedNotchHeight - 12
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .frame(
                    width: isExpanded ? max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12) + gestureProgress / 2) : 0,
                    height: vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)
                )
            
            // Center: closed notch body (slightly wider during downloads)
            Rectangle()
                .fill(.black)
                .frame(
                    width: vm.closedNotchSize.width
                        + (isHovering ? 8 : 0)
                        + (downloadManager.isDownloading ? 40 : 0)
                )
            
            // Right side: indeterminate-style progress bar
            Color.clear
                .background {
                    if isExpanded {
                        HStack {
                            if downloadManager.isDownloadCompleted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 16, weight: .semibold))
                                    .padding(.trailing, 6)
                            } else {
                                HStack(spacing: 6) {
                                    if indicatorStyle == .circle {
                                        SpinningCircleDownloadView(progress: downloadManager.downloadProgress)
                                    } else {
                                        if let progress = downloadManager.downloadProgress {
                                            ProgressView(value: progress, total: 1)
                                                .progressViewStyle(.linear)
                                                .tint(.accentColor)
                                                .frame(width: 40)
                                        } else {
                                            ProgressView()
                                                .progressViewStyle(.linear)
                                                .tint(.accentColor)
                                                .frame(width: 40)
                                        }
                                    }
                                }
                                .padding(.trailing, 6)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                }
                .frame(
                    width: isExpanded ? max(60, vm.effectiveClosedNotchHeight) : 0,
                    height: vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)
                )
        }
        .frame(height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0))
        .onAppear {
            withAnimation(.smooth(duration: 0.35)) {
                isExpanded = true
            }
        }
        .onChange(of: downloadManager.isDownloading) { _, newValue in
            withAnimation(.smooth(duration: 0.35)) {
                isExpanded = newValue
            }
        }
    }
}
