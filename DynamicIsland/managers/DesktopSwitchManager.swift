import AppKit
import Combine
import Defaults
import Darwin

/// A snapshot of ordinary Mission Control desktops, independent of window IDs.
struct DesktopSpaceSnapshot: Equatable {
    var numbers: [String: Int]

    static func decode(_ displays: [[String: Any]]) -> Self {
        var numbers: [String: Int] = [:]
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  let current = display["Current Space"] as? [String: Any],
                  let currentID = spaceID(current) else { continue }
            // Zero records a known display currently showing a full-screen Space.
            numbers[identifier] = 0
            // Full-screen app Spaces do not get a misleading Desktop number.
            let desktops = spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }
            if let index = desktops.firstIndex(where: { spaceID($0) == currentID }) {
                numbers[identifier] = index + 1
            }
        }
        return Self(numbers: numbers)
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        (space["id64"] as? NSNumber)?.uint64Value
            ?? (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    func changes(from previous: Self) -> [String: Int] {
        // A newly attached screen establishes a baseline, not a switch toast.
        numbers.filter { $0.value > 0 && previous.numbers[$0.key] != nil && previous.numbers[$0.key] != $0.value }
    }
}

/// Read-only query. Resolve the existing WindowServer API at runtime so an
/// unavailable API simply disables the indicator rather than preventing launch.
enum DesktopSpaceReader {
    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static func read() -> DesktopSpaceSnapshot? {
        typealias Connection = @convention(c) () -> UInt32
        typealias CopySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
        guard let library,
              let connectionSymbol = dlsym(library, "CGSMainConnectionID"),
              let spacesSymbol = dlsym(library, "CGSCopyManagedDisplaySpaces") else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
        let copySpaces = unsafeBitCast(spacesSymbol, to: CopySpaces.self)
        guard let displays = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty else { return nil }
        return DesktopSpaceSnapshot.decode(displays)
    }
}

@MainActor
final class DesktopSwitchManager {
    static let shared = DesktopSwitchManager()
    private var previous: DesktopSpaceSnapshot?
    private var subscriptions = Set<AnyCancellable>()
    private var pendingRefresh: Task<Void, Never>?

    private init() {
        previous = DesktopSpaceReader.read()
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &subscriptions)
        // Wake/display changes establish a fresh baseline silently.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.resetBaseline() }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resetBaseline() }.store(in: &subscriptions)
    }

    private func resetBaseline() {
        pendingRefresh?.cancel()
        previous = DesktopSpaceReader.read()
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            // Coalesce fast gestures and let WindowServer finish its snapshot.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        guard let snapshot = DesktopSpaceReader.read() else { return }
        let old = previous
        previous = snapshot
        guard let old, Defaults[.enableDesktopSwitchIndicator],
              Defaults[.enableSystemHUD], !LockScreenManager.shared.isLocked else { return }
        let changes = snapshot.changes(from: old)
        guard !changes.isEmpty else { return }
        let coordinator = DynamicIslandViewCoordinator.shared
        guard Self.canPresent(over: coordinator.sneakPeek) else { return }
        let screens = NSScreen.screens.sorted { ($0 == NSScreen.main ? 0 : 1) < ($1 == NSScreen.main ? 0 : 1) }
        for screen in screens {
            guard let identifier = Self.displayIdentifier(screen),
                  let number = changes[identifier] ?? changes["Main"] else { continue }
            coordinator.toggleSneakPeek(status: true, type: .desktop, duration: 2,
                value: CGFloat(number), icon: "rectangle.on.rectangle", onScreen: screen)
            break
        }
    }

    static func canPresent(over current: sneakPeek) -> Bool {
        !current.show || current.type == .music || current.type == .desktop
    }

    private static func displayIdentifier(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
