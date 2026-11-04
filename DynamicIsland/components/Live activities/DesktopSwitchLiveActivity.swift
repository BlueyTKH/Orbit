import SwiftUI

enum DesktopSwitchLayout {
    static func wingWidth(height: CGFloat) -> CGFloat { max(height - 12, 24) }
    static func contentSize(closedSize: CGSize) -> CGSize {
        CGSize(width: closedSize.width + 2 * wingWidth(height: closedSize.height), height: closedSize.height)
    }
}

/// Two small wings around the camera, like the minimal Focus activity.
struct DesktopSwitchLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    let number: Int

    var body: some View {
        let height = vm.effectiveClosedNotchHeight
        let wingWidth = DesktopSwitchLayout.wingWidth(height: height)
        HStack(spacing: 0) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: wingWidth)
            Color.clear.frame(width: vm.closedNotchSize.width)
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .frame(width: wingWidth)
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Desktop \(number)")
    }
}
