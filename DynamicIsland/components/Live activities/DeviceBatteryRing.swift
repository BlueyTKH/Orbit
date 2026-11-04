import SwiftUI

/// A device glyph inside the battery arc, like an accessory battery widget.
/// Callers retain control of the existing indicator/percentage preferences.
struct DeviceBatteryRing: View {
    let value: CGFloat
    let useColorCoding: Bool
    let smoothGradient: Bool
    var diameter: CGFloat = 16
    var symbol: String? = nil
    private var clampedValue: CGFloat { min(max(value.isFinite ? value : 0, 0), 1) }
    private var lineWidth: CGFloat { diameter >= 40 ? 3.5 : 2.2 }
    private var tint: Color {
        useColorCoding ? ColorCodedProgressBar.paletteColor(for: clampedValue, mode: .battery, smoothGradient: smoothGradient) : .white
    }
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: diameter == 16 ? 2 : lineWidth)
            Circle().trim(from: 0, to: diameter == 16 ? max(clampedValue, 0.015) : clampedValue)
                .rotation(.degrees(-90))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if let symbol {
                Image(systemName: symbol).font(.system(size: diameter * 0.43, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.smooth(duration: 0.18), value: clampedValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue("\(Int((clampedValue * 100).rounded())) percent")
    }
}
