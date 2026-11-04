import AppKit
import Combine
import QuartzCore

enum CriticalBatteryBorderLayout {
    static let glowWidth: CGFloat = 72
    static let textureSize: CGFloat = 160
    // Only the transparent centre stretches; edge/corner falloff stays the same
    // width on every display. This avoids a screen-sized bitmap or drawing loop.
    static let stretchCenter = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)

    static func makeGlowImage(scale: CGFloat, cornerRadius: CGFloat) -> CGImage? {
        let scale = max(1, scale)
        let pixels = Int((textureSize * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setBlendMode(.copy)
        let bounds = CGRect(x: 0, y: 0, width: textureSize, height: textureSize)
        // Nested fills replace alpha rather than stacking it: a continuous soft
        // vignette with no opaque stroke and no doubled brightness at corners.
        for pixel in 0...Int(glowWidth * scale) {
            let depth = CGFloat(pixel) / scale
            let fraction = depth / glowWidth
            let fade = max(0, min(1, (glowWidth - depth) / 12))
            let alpha = 0.76 * exp(-pow(depth / 25, 2) / 2) * fade * fade * (3 - 2 * fade)
            context.setFillColor(red: 1 - 0.06 * fraction,
                green: 0.16 - 0.12 * fraction, blue: 0.13, alpha: alpha)
            let rect = bounds.insetBy(dx: depth, dy: depth)
            let radius = max(0, cornerRadius - depth)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        return context.makeImage()
    }
}

private final class CriticalBatteryBorderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CriticalBatteryBorderView: NSView {
    private let glow = CALayer()

    init(frame: NSRect, scale: CGFloat = 2, cornerRadius: CGFloat = 18) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glow.contents = CriticalBatteryBorderLayout.makeGlowImage(scale: scale, cornerRadius: cornerRadius)
        glow.contentsScale = max(1, scale)
        glow.contentsCenter = CriticalBatteryBorderLayout.stretchCenter
        glow.contentsGravity = .resize
        layer?.addSublayer(glow)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.6
            pulse.toValue = 1
            pulse.duration = 1.4
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(pulse, forKey: "criticalBatteryPulse")
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }
}

/// A brief, click-through edge glow. It never activates or sizes the notch host.
@MainActor
final class CriticalBatteryBorderManager {
    static let shared = CriticalBatteryBorderManager()
    private var panels: [NSPanel] = []
    private var expiry: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        LockScreenManager.shared.$isLocked.removeDuplicates()
            .sink { [weak self] locked in if locked { self?.dismiss() } }
            .store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.dismiss() }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.dismiss() }.store(in: &subscriptions)
    }

    func show(screenName: String?, duration: TimeInterval) {
        dismiss()
        guard !LockScreenManager.shared.isLocked else { return }
        let screens = NSScreen.screens.filter { screenName == nil || $0.localizedName == screenName }
        for screen in screens {
            let panel = CriticalBatteryBorderPanel(contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = CriticalBatteryBorderView(frame: CGRect(origin: .zero, size: screen.frame.size),
                scale: screen.backingScaleFactor, cornerRadius: screen.safeAreaInsets.top > 0 ? 18 : 0)
            panel.contentView?.needsLayout = true
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(max(duration, 1), 60)))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        expiry?.cancel()
        expiry = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
    }
}
