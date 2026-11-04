import AppKit
import ApplicationServices
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI

enum NotchSnapLayout: String, CaseIterable {
    case left = "Left", right = "Right", maximize = "Fill", restore = "Restore"
    var symbol: String {
        switch self { case .left: return "rectangle.lefthalf.filled"
        case .right: return "rectangle.righthalf.filled"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .restore: return "arrow.uturn.backward" }
    }
}

@MainActor
final class WindowSnapManager: ObservableObject {
    static let shared = WindowSnapManager()
    @Published private(set) var message = "Arrange the last active app window."
    @Published private(set) var dragSelection: NotchSnapLayout?
    private var dragPanel: NSPanel?
    private var dragHost: NSHostingView<WindowSnapDragView>?
    private var dragHeaderHeight: CGFloat = 0
    private var dragPresentationFrame: CGRect?
    private var dragWindow: AXUIElement?
    private var dragActive = false
    private var dragMonitor: Any?
    private var axObserver: AXObserver?
    private var observerGeneration = 0
    private var foreground: NSRunningApplication?
    private var subscriptions = Set<AnyCancellable>()
    private var panel: NotchFlowUtilityWindow?
    private let worker = DispatchQueue(label: "com.kayhsen.NotchFlow.window-snap", qos: .userInitiated)
    // Accessed only on the serial worker; restoring retains the actual AX window identity.
    private final class Storage: @unchecked Sendable { var originals: [(AXUIElement, CGRect)] = [] }
    private let storage = Storage()
    private init() {
        remember(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] note in
                self?.remember(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }.store(in: &subscriptions)
        KeyboardShortcuts.onKeyDown(for: .notchSnapLeft) { Task { @MainActor in self.snap(.left) } }
        KeyboardShortcuts.onKeyDown(for: .notchSnapRight) { Task { @MainActor in self.snap(.right) } }
        KeyboardShortcuts.onKeyDown(for: .notchSnapFill) { Task { @MainActor in self.snap(.maximize) } }
        KeyboardShortcuts.onKeyDown(for: .notchSnapRestore) { Task { @MainActor in self.snap(.restore) } }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if event.type == .leftMouseUp { self.endDrag() }
                else if self.dragActive { self.updateDragCue() }
            }
        }
        Defaults.publisher(.snapDragEnabled, options: []).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDragObserver() }.store(in: &subscriptions)
        refreshDragObserver()
    }
    private func remember(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let changed = foreground?.processIdentifier != app.processIdentifier
            foreground = app
            if changed { refreshDragObserver() }
        }
    }
    func show() {
        remember(NSWorkspace.shared.frontmostApplication)
        if panel == nil { panel = NotchFlowUtilityWindow(title: "Orbit · Arrange windows", size: CGSize(width: 420, height: 175), resizable: false, content: WindowSnapView()) }
        panel?.show()
    }
    nonisolated static func target(_ layout: NotchSnapLayout, visibleFrame: CGRect, ratio: Double) -> CGRect {
        let split = min(0.7, max(0.3, ratio))
        switch layout {
        case .left: return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width * split, height: visibleFrame.height)
        case .right: return CGRect(x: visibleFrame.minX + visibleFrame.width * split, y: visibleFrame.minY, width: visibleFrame.width * (1 - split), height: visibleFrame.height)
        default: return visibleFrame
        }
    }
    nonisolated static func accessibilityRect(_ cocoa: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: cocoa.minX, y: primaryTop - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }
    func snap(_ layout: NotchSnapLayout, windowOverride: AXUIElement? = nil) {
        guard AXIsProcessTrusted() else { message = "Enable Orbit in Privacy & Security → Accessibility."; return }
        remember(NSWorkspace.shared.frontmostApplication)
        guard let app = foreground, !app.isTerminated else { message = "Select an app window first."; return }
        let pid = app.processIdentifier
        let screens = NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let ratio = Defaults[.snapSplitRatio]
        let state = storage
        message = "Arranging \(app.localizedName ?? "window")…"
        worker.async { [weak self] in
            guard let self else { return }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 1)
            var focused: CFTypeRef?
            if let windowOverride { focused = windowOverride }
            else { _ = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) }
            guard
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                Task { @MainActor in self.message = "This app has no available window." }; return
            }
            let window = unsafeBitCast(focused, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(window, 1)
            var canMove = DarwinBoolean(false), canResize = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &canMove) == .success,
                  AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &canResize) == .success,
                  canMove.boolValue, canResize.boolValue else {
                Task { @MainActor in self.message = "This window does not support moving and resizing." }; return
            }
            func read<T>(_ name: String, type: AXValueType, initial: T) -> T? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, name as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
                var result = initial
                return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), type, &result) ? result : nil
            }
            guard let position: CGPoint = read(kAXPositionAttribute, type: .cgPoint, initial: .zero),
                  let size: CGSize = read(kAXSizeAttribute, type: .cgSize, initial: .zero) else {
                Task { @MainActor in self.message = "This window cannot be arranged." }; return
            }
            let original = CGRect(origin: position, size: size)
            let existing = state.originals.firstIndex { CFEqual($0.0, window) }
            var target: CGRect
            if layout == .restore {
                guard let existing else { Task { @MainActor in self.message = "No previous position saved for this window." }; return }
                target = state.originals[existing].1
            } else {
                let cocoa = CGRect(x: position.x, y: primaryTop - position.y - size.height, width: size.width, height: size.height)
                guard let screen = screens.max(by: { $0.0.intersection(cocoa).area < $1.0.intersection(cocoa).area }) else { return }
                target = Self.accessibilityRect(Self.target(layout, visibleFrame: screen.1, ratio: ratio), primaryTop: primaryTop)
            }
            var point = target.origin, dimensions = target.size
            guard let pointValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &dimensions) else { return }
            let resize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            // Keep restoration available even if an app only accepts part of the request.
            if layout != .restore && existing == nil && resize == .success {
                state.originals.append((window, original))
                if state.originals.count > 40 { state.originals.removeFirst() }
            }
            let move = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
            let finalResize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            let success = resize == .success && move == .success && finalResize == .success
            if success {
                if layout == .restore, let existing { state.originals.remove(at: existing) }
            }
            Task { @MainActor in self.message = success ? "\(layout.rawValue) applied. Some apps enforce a minimum size." : "This app does not allow that window arrangement." }
        }
    }

    private func refreshDragObserver() {
        observerGeneration += 1
        let generation = observerGeneration
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        axObserver = nil
        endDrag(apply: false)
        guard Defaults[.snapDragEnabled], AXIsProcessTrusted(), let app = foreground else { return }
        let pid = app.processIdentifier
        let reference = Unmanaged.passUnretained(self).toOpaque()
        worker.async { [weak self] in
            var observer: AXObserver?
            guard AXObserverCreate(pid, notchFlowSnapObserverCallback, &observer) == .success, let observer else { return }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 1)
            _ = AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString, reference)
            _ = AXObserverAddNotification(observer, application, kAXWindowMovedNotification as CFString, reference)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(value, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(window, 1)
                _ = AXObserverAddNotification(observer, window, kAXWindowMovedNotification as CFString, reference)
            }
            Task { @MainActor in
                guard let self, self.observerGeneration == generation else { return }
                self.axObserver = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }

    fileprivate func observerEvent(_ window: AXUIElement, notification: String) {
        if notification == kAXFocusedWindowChangedNotification { refreshDragObserver(); return }
        guard Defaults[.snapDragEnabled], NSEvent.pressedMouseButtons & 1 != 0 else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid == foreground?.processIdentifier else { return }
        dragWindow = window; dragActive = true; updateDragCue()
    }

    private func updateDragCue() {
        guard !NSEvent.modifierFlags.contains(.command) else {
            dragPanel?.orderOut(nil); dragSelection = nil; return
        }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let topInset = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let nearTop = abs(point.x - screen.frame.midX) <= 260 && point.y >= screen.frame.maxY - topInset - 38
        let frame = CGRect(x: screen.frame.midX - 180, y: screen.frame.maxY - topInset - 90, width: 360, height: topInset + 90)
        if nearTop || (dragPanel?.isVisible == true && frame.insetBy(dx: -80, dy: -70).contains(point)) {
            if dragPanel == nil {
                let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = .mainMenu + 4; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
                let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
                let host = NSHostingView(rootView: WindowSnapDragView(headerHeight: topInset))
                host.sizingOptions = []; host.frame = container.bounds; host.autoresizingMask = [.width, .height]
                container.addSubview(host); panel.contentView = container
                dragHost = host; dragHeaderHeight = topInset
                ScreenCaptureVisibilityManager.shared.register(panel, scope: .panelsOnly)
                dragPanel = panel
            }
            if dragHeaderHeight != topInset {
                dragHost?.rootView = WindowSnapDragView(headerHeight: topInset); dragHeaderHeight = topInset
            }
            if let panel = dragPanel, !panel.isVisible {
                let physicalWidth = screen.auxiliaryTopLeftArea.flatMap { left in
                    screen.auxiliaryTopRightArea.map { $0.minX - left.maxX }
                } ?? 160
                let width = max(80, min(360, physicalWidth))
                let collapsed = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - topInset, width: width, height: max(1, topInset))
                panel.setFrame(collapsed, display: false); panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18; panel.animator().setFrame(frame, display: true)
                }
                dragPresentationFrame = frame
            } else if dragPresentationFrame != frame {
                dragPanel?.setFrame(frame, display: true); dragPresentationFrame = frame
            }
            let tilesFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 90)
            dragSelection = Self.selection(at: point, panelFrame: tilesFrame)
        } else { dragPanel?.orderOut(nil); dragSelection = nil }
    }

    nonisolated static func selection(at point: CGPoint, panelFrame: CGRect) -> NotchSnapLayout? {
        guard point.y >= panelFrame.maxY - 60, point.y <= panelFrame.maxY - 10 else { return nil }
        let x = point.x - panelFrame.minX - 12
        guard x >= 0 else { return nil }
        let index = Int(x / 86)
        guard index < 4, x - Double(index) * 86 <= 78 else { return nil }
        return NotchSnapLayout.allCases[index]
    }

    private func endDrag(apply: Bool = true) {
        if apply, dragActive, !NSEvent.modifierFlags.contains(.command), let dragPanel, dragPanel.isVisible,
           let target = dragPresentationFrame,
           let layout = Self.selection(at: NSEvent.mouseLocation, panelFrame: CGRect(x: target.minX, y: target.minY, width: target.width, height: 90)), let window = dragWindow {
            snap(layout, windowOverride: window)
        }
        dragPanel?.orderOut(nil); dragActive = false; dragWindow = nil; dragSelection = nil
    }
}

private func notchFlowSnapObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ reference: UnsafeMutableRawPointer?) {
    guard let reference else { return }
    let manager = Unmanaged<WindowSnapManager>.fromOpaque(reference).takeUnretainedValue()
    let name = notification as String
    Task { @MainActor in manager.observerEvent(element, notification: name) }
}

private struct WindowSnapDragView: View {
    @ObservedObject private var snap = WindowSnapManager.shared
    let headerHeight: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: headerHeight).accessibilityHidden(true)
            VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(NotchSnapLayout.allCases, id: \.self) { layout in
                    VStack(spacing: 4) { Image(systemName: layout.symbol); Text(layout.rawValue).font(.caption) }
                        .frame(width: 78, height: 50)
                        .background(snap.dragSelection == layout ? Color.mint.opacity(0.35) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("Drag onto a layout, then release").font(.caption2).foregroundStyle(.secondary)
            }.padding(12).frame(height: 90)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white)
            .background(.black, in: NotchShape(topCornerRadius: 8, bottomCornerRadius: 20))
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

private struct WindowSnapView: View {
    @ObservedObject private var snap = WindowSnapManager.shared
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                ForEach(NotchSnapLayout.allCases, id: \.self) { layout in
                    Button { snap.snap(layout) } label: {
                        VStack(spacing: 8) { Image(systemName: layout.symbol).font(.title2); Text(layout.rawValue) }
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }
            }
            Text(snap.message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
