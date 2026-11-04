import SwiftUI
import Defaults

struct AccessoryConnectionActivityView: View {
    let event: AccessoryConnectionEvent
    let style: BatteryNotificationStyle
    let closedNotchWidth: CGFloat
    let baseHeight: CGFloat
    let isDynamicIslandMode: Bool
    let topCornerRadius: CGFloat
    @Default(.useCircularBluetoothBatteryIndicator) private var circularBattery
    @Default(.showBluetoothBatteryPercentageText) private var showPercentage
    @Default(.useColorCodedBatteryDisplay) private var colorCodedBattery
    @Default(.useSmoothColorGradient) private var smoothGradient
    private var usesBatteryRing: Bool { event.kind != .airPods && event.connected && event.main != nil && circularBattery }
    private var tint: Color { event.connected ? .green : .white.opacity(0.65) }
    private var shape: AnyShape {
        isDynamicIslandMode ? AnyShape(DynamicIslandPillShape(cornerRadius: dynamicIslandPillCornerRadiusInsets.opened))
            : AnyShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: style == .compact ? max(baseHeight / 2, 16) : 40))
    }
    var body: some View {
        let size = AccessoryConnectionLayout.surface(closed: CGSize(width: closedNotchWidth, height: baseHeight), style: style)
        Group {
            if style == .compact {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        connectionArtwork(size: 16)
                        Text(event.status).font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(.trailing, AccessoryConnectionLayout.cameraClearance)
                    .frame(width: AccessoryConnectionLayout.wingWidth, alignment: .leading)
                    Color.clear.frame(width: closedNotchWidth)
                    Group {
                        if !event.connected {
                            Text("AirPods").font(.system(size: 12, weight: .semibold, design: .rounded))
                        } else if event.left != nil || event.right != nil {
                            VStack(alignment: .trailing, spacing: 1) {
                                if let left = event.left { Text("L  \(left)%") }
                                if let right = event.right { Text("R  \(right)%") }
                            }
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                        } else if let main = event.main {
                            HStack(spacing: 8) {
                                if usesBatteryRing {
                                    DeviceBatteryRing(value: CGFloat(main) / 100, useColorCoding: colorCodedBattery,
                                        smoothGradient: smoothGradient, diameter: 24, symbol: event.symbol)
                                }
                                if !usesBatteryRing || showPercentage {
                                    Text("\(main)%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                                }
                            }
                        } else { Text("—").font(.system(size: 12)) }
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.leading, AccessoryConnectionLayout.cameraClearance)
                    .frame(width: AccessoryConnectionLayout.wingWidth, alignment: .trailing)
                }
                .padding(.horizontal, AccessoryConnectionLayout.outerPadding)
                .frame(height: baseHeight)
            } else {
                VStack(spacing: 0) {
                    Color.clear.frame(height: baseHeight)
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.status).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                            Text(verbatim: event.name).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9)).lineLimit(1).truncationMode(.tail)
                            if !event.detail.isEmpty && (!usesBatteryRing || showPercentage) {
                                Text(verbatim: event.detail).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if usesBatteryRing, let level = event.main {
                            DeviceBatteryRing(value: CGFloat(level) / 100, useColorCoding: colorCodedBattery,
                                smoothGradient: smoothGradient, diameter: 48, symbol: event.symbol)
                                .fixedSize()
                        } else {
                            connectionArtwork(size: event.kind == .airPods ? 40 : 32)
                                .frame(width: event.kind == .airPods ? 44 : 36).fixedSize()
                        }
                    }.padding(.horizontal, 32).frame(height: 88)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.name), \(event.status), \(event.detail)")
    }
    @ViewBuilder
    private func connectionArtwork(size: CGFloat) -> some View {
        if event.kind == .airPods {
            AirPodsCaseArtwork(symbol: event.symbol, model: event.artworkModel ?? .resolve(symbol: event.symbol, name: event.name),
                connected: event.connected, size: size)
        } else {
            Image(systemName: event.symbol).font(.system(size: size)).foregroundStyle(tint)
        }
    }

}


/// Offline 3D product frames, rendered at six times expanded icon size.
/// Playback uses no live SceneKit renderer and stops updating after one pass.
struct AirPodsCaseArtwork: View {
    let symbol: String
    let model: AirPodsArtworkModel
    let connected: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
    @State private var finished = false
    private var playbackID: String { model.rawValue + String(connected) + String(reduceMotion) }
    var body: some View {
        Group {
            if model == .max || reduceMotion {
                Image(systemName: symbol).font(.system(size: size))
                    .foregroundStyle(.white.opacity(connected ? 0.95 : 0.6))
            } else {
                TimelineView(.animation(minimumInterval: 1.0/24, paused: finished)) { context in
                    // Hold the connected open pose until the card itself dismisses.
                    let elapsed = finished ? AirPodsArtworkModel.duration : context.date.timeIntervalSince(startedAt)
                    let index = AirPodsArtworkModel.frame(elapsed: elapsed, connected: connected)
                    if let frame = AirPodsArtworkFrames.image(model: model, index: index) {
                        Image(nsImage: frame).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: symbol).font(.system(size: size)).foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size * 1.35)
        .accessibilityHidden(true)
        .task(id: playbackID) {
            guard !reduceMotion, model != .max else { finished = true; return }
            startedAt = Date(); finished = false
            try? await Task.sleep(for: .seconds(AirPodsArtworkModel.duration))
            guard !Task.isCancelled else { return }
            finished = true
        }
    }
}

private enum AirPodsArtworkFrames {
    // Keep only recently used families. Cropped CGImages share their atlas data.
    private static let cache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>(); cache.countLimit = 2; return cache
    }()
    static func image(model: AirPodsArtworkModel, index: Int) -> NSImage? {
        let key = model.rawValue as NSString
        let frames: [NSImage]
        if let cached = cache.object(forKey: key) as? [NSImage] { frames = cached }
        else {
            guard let source = NSImage(named: model.assetName),
                  let atlas = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  atlas.width % 8 == 0, atlas.height % 8 == 0 else { return nil }
            let w = atlas.width / 8, h = atlas.height / 8
            frames = (0..<AirPodsArtworkModel.frameCount).compactMap { frame in
                guard let tile = atlas.cropping(to: CGRect(x: (frame%8)*w, y: (frame/8)*h, width: w, height: h)) else { return nil }
                return NSImage(cgImage: tile, size: NSSize(width: 32, height: 43.2))
            }
            guard frames.count == AirPodsArtworkModel.frameCount else { return nil }
            cache.setObject(frames as NSArray, forKey: key)
        }
        return frames[min(max(index,0),frames.count-1)]
    }
}
