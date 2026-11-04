import XCTest
import AppKit
import SwiftUI
@testable import NotchFlow

final class BatteryMenuSnapshotTests: XCTestCase {
    func testNativeMacAlertRequiresMacIdentityAndVerifiedHost() {
        let match = MacNativeBatteryAlertMatcher.matches
        XCTAssertTrue(match("com.apple.controlcenter", ["Low Battery", "Your Mac will sleep soon unless plugged into a power outlet."], 320, 100))
        XCTAssertFalse(match("com.apple.controlcenter", ["Low Battery", "Kay’s AirPods", "5"], 320, 100))
        XCTAssertFalse(match("com.apple.notificationcenterui", ["Low Battery"], 320, 100))
        XCTAssertFalse(match("com.example.app", ["Low Battery", "Your Mac"], 320, 100))
        XCTAssertFalse(match("com.apple.controlcenter", ["Low Battery", "Your Mac"], 900, 700))
        XCTAssertFalse(match("com.apple.controlcenter", ["Your Mac", "Connected"], 320, 100))
    }
    @MainActor func testMenuStatesAndInstantaneousCurrent() {
        for level in [31, 49, 50, 80] {
            XCTAssertEqual(BatteryMenuIcon.tint(level: level, charging: false, lowPower: false), .systemGreen)
        }
        for level in [20, 25, 30] {
            XCTAssertEqual(BatteryMenuIcon.tint(level: level, charging: false, lowPower: false), .systemOrange)
        }
        XCTAssertEqual(BatteryMenuIcon.tint(level: 8, charging: false, lowPower: false), .systemRed)
        XCTAssertEqual(BatteryMenuIcon.tint(level: 8, charging: false, lowPower: true), .systemYellow)
        var data = reading(plugged: false, charging: false, current: -1000)
        data["InstantAmperage"] = -2000
        let value = BatteryMenuSnapshot.parse(data, lowPower: true)
        XCTAssertEqual(value.batteryWatts, -24)
        XCTAssertEqual(value.state, "On battery (Low Power Mode)")
        data["InstantAmperage"] = 999999
        XCTAssertEqual(BatteryMenuSnapshot.parse(data, lowPower: false).batteryWatts, -12)
    }
    func testWidgetAutomaticSelectionIgnoresStaleOfflineAndInvalidReadings() {
        let now = Date()
        func device(_ id: String, _ level: Int?, age: Double = 0, connected: Bool = true) -> OrbitBatteryDevice {
            .init(id: id, name: id, symbol: "iphone", level: level, charging: false,
                connected: connected, observedAt: now.addingTimeInterval(-age), detail: "")
        }
        let snapshot = OrbitBatterySnapshot(writtenAt: now, devices: [device("high", 90), device("low", 8),
            device("stale", 1, age: 181), device("offline", 2, connected: false), device("invalid", 101), device("unknown", nil)])
        XCTAssertEqual(snapshot.selected(ids: [], at: now).map(\.id), ["low", "high"])
        XCTAssertEqual(snapshot.selected(ids: ["high", "offline", "high", "missing", "low"], at: now).map(\.id), ["high", "offline", "low"])
        XCTAssertNil(snapshot.devices[2].usableLevel(at: now))
        XCTAssertTrue(snapshot.selected(ids: [], at: now.addingTimeInterval(181)).isEmpty)
    }
    func testWidgetSnapshotRoundTripsWithoutBatteryHistory() throws {
        let snapshot = OrbitBatterySnapshot(writtenAt: Date(), devices: [])
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(OrbitBatterySnapshot.self, from: data), snapshot)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("history"))
    }
    func testMobileAndBluetoothBatteryValidation() {
        XCTAssertEqual(TrustedDeviceBatteryReader.percentage(NSNumber(value: 1)), 1)
        XCTAssertNil(TrustedDeviceBatteryReader.percentage(NSNumber(value: true)))
        XCTAssertNil(TrustedDeviceBatteryReader.percentage(NSNumber(value: 1.5)))
        XCTAssertNil(TrustedDeviceBatteryReader.percentage(NSNumber(value: 101)))
        XCTAssertEqual(NearbyBatteryManager.decodeLevel(Data([0])), 0)
        XCTAssertEqual(NearbyBatteryManager.decodeLevel(Data([100])), 100)
        XCTAssertNil(NearbyBatteryManager.decodeLevel(Data()))
        XCTAssertNil(NearbyBatteryManager.decodeLevel(Data([255])))
        XCTAssertNil(NearbyBatteryManager.decodeLevel(Data([1, 2])))
    }
    @MainActor func testOrbitSettingsOffscreenLayouts() throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" { throw XCTSkip("Local visual QA requires AppKit rendering") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/diagnostics/orbit-3.0.0/settings-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for page in ["general", "widgets", "battery", "about"] {
            for dark in [false, true] {
                let state = SettingsNavigationState(); state.selectedTabID = page
                let content = SettingsView(navigationState: state).environment(\.colorScheme, dark ? .dark : .light).preferredColorScheme(dark ? .dark : .light)
                let view = NSHostingView(rootView: content); view.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view; window.setContentSize(NSSize(width: 940, height: 700))
                view.frame = NSRect(x: 0, y: 0, width: 940, height: 700)
                view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("settings-" + page + (dark ? "-dark.png" : "-light.png")))
                XCTAssertEqual(view.bounds.size, NSSize(width: 940, height: 700))
                window.contentView = nil
            }
        }
    }
    func testOrbitDataMigrationRetainsConflictingFilesAndMergesHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("NotchFlow"), destination = root.appendingPathComponent("Orbit")
        for directory in [old, destination] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("BatteryHistory"), withIntermediateDirectories: true)
        }
        try Data("legacy note".utf8).write(to: old.appendingPathComponent("notes.txt"))
        try Data("new note".utf8).write(to: destination.appendingPathComponent("notes.txt"))
        try Data("saved icon".utf8).write(to: old.appendingPathComponent("icon.png"))
        try JSONSerialization.data(withJSONObject: [["date": 1, "level": 40], ["date": 2, "level": 30]]).write(to: old.appendingPathComponent("BatteryHistory/samples.json"))
        try JSONSerialization.data(withJSONObject: [["date": 2, "level": 31], ["date": 3, "level": 20]]).write(to: destination.appendingPathComponent("BatteryHistory/samples.json"))
        try OrbitDataMigration.migrate(from: old, to: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8), "new note")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("icon.png"), encoding: .utf8), "saved icon")
        let recovered = try FileManager.default.contentsOfDirectory(at: destination.appendingPathComponent("Migration Recovered"), includingPropertiesForKeys: nil)
        XCTAssertTrue(try recovered.contains { try Data(contentsOf: $0) == Data("legacy note".utf8) })
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("BatteryHistory/samples.json"))) as? [[String: Int]])
        XCTAssertEqual(records.map { $0["date"]! }, [1, 2, 3])
        XCTAssertEqual(records[1]["level"], 31)
        // Re-running migration must not alter the preserved files.
        try OrbitDataMigration.migrate(from: old, to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8), "new note")
    }
    func testAnimationRelocationKeepsIdentityAndPlaybackChoices() {
        let legacy = URL(fileURLWithPath: "/example/NotchFlow"), support = URL(fileURLWithPath: "/example/Orbit")
        let original = CustomIdleAnimation(name: "My animation", source: .lottieFile(legacy.appendingPathComponent("IdleAnimations/custom.json")), speed: 0.7)
        let updated = OrbitAnimationRelocation.relocate(original, bundledFiles: [:], legacySupport: legacy, support: support)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.name, original.name)
        XCTAssertEqual(updated.speed, original.speed)
        XCTAssertEqual(updated.source, .lottieFile(support.appendingPathComponent("IdleAnimations/custom.json")))
        let builtIn = CustomIdleAnimation(name: "Dog", source: .lottieFile(URL(fileURLWithPath: "/Applications/NotchFlow.app/Contents/Resources/Dog.json")), speed: 1.2, isBuiltIn: true)
        let replacement = URL(fileURLWithPath: "/Applications/Orbit.app/Contents/Resources/Dog.json")
        let relocated = OrbitAnimationRelocation.relocate(builtIn, bundledFiles: ["Dog.json": replacement], legacySupport: legacy, support: support)
        XCTAssertEqual(relocated.id, builtIn.id)
        XCTAssertEqual(relocated.speed, builtIn.speed)
        XCTAssertEqual(relocated.source, .lottieFile(replacement))
        let remote = CustomIdleAnimation(name: "Remote", source: .lottieURL(URL(string: "https://example.com/animation.json")!))
        XCTAssertEqual(OrbitAnimationRelocation.relocate(remote, bundledFiles: [:], legacySupport: legacy, support: support), remote)
    }
    func testDuplicateTabletReadersCombineWithoutLosingPinnedAliases() {
        let now = Date()
        func record(_ id: String, name: String = "Study iPad", symbol: String = "ipad", level: Int = 45) -> OrbitBatteryDevice {
            .init(id: id, name: name, symbol: symbol, level: level, charging: id.hasPrefix("mobile:"), connected: true, observedAt: now, detail: "")
        }
        let records = [record("nearby:old"), record("nearby:new"), record("mobile:trusted", level: 44),
            record("left", name: "AirPods · Left", symbol: "airpods"), record("right", name: "AirPods · Right", symbol: "airpods")]
        let combined = OrbitDeviceReconciler.reconcile(records, combine: true, at: now)
        XCTAssertEqual(combined.count, 3)
        let tablet = combined.first { $0.symbol == "ipad" }!
        XCTAssertEqual(tablet.level, 44)
        XCTAssertTrue(tablet.charging)
        XCTAssertEqual(Set(tablet.aliases ?? []), Set(["nearby:old", "nearby:new", "mobile:trusted"]))
        let snapshot = OrbitBatterySnapshot(writtenAt: now, devices: combined)
        XCTAssertEqual(snapshot.selected(ids: ["nearby:old", "nearby:new"], at: now).count, 1)
        XCTAssertEqual(OrbitDeviceReconciler.reconcile(records, combine: false, at: now).count, 5)
        XCTAssertNil(OrbitDeviceReconciler.phoneKey(name: "iPad"))
        XCTAssertNil(OrbitDeviceReconciler.phoneKey(name: "Study iPad Keyboard", symbol: "keyboard"))
    }
    func testDiscoveryCollapsesMatchingTabletNamesAndExpiresOldAdvertisements() {
        let now = Date()
        let candidates = [NearbyBatteryCandidate(id: "old", name: "Study iPad"), .init(id: "new", name: "Study iPad"),
            .init(id: "expired", name: "Old iPhone"), .init(id: "one", name: "iPad"), .init(id: "two", name: "iPad")]
        let seen = ["old": now.addingTimeInterval(-5), "new": now, "expired": now.addingTimeInterval(-91), "one": now, "two": now]
        let result = OrbitDeviceReconciler.discoveryCandidates(candidates, lastSeen: seen, tracked: ["old"], combine: true, at: now)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.contains { $0.id == "old" })
        XCTAssertFalse(result.contains { $0.id == "expired" })
        XCTAssertEqual(OrbitDeviceReconciler.discoveryCandidates(candidates, lastSeen: seen, tracked: [], combine: false, at: now).count, 4)
    }
    func testCanonicalTabletRemainsVisibleOnceInBatteryMenu() {
        XCTAssertTrue(OrbitDeviceReconciler.isPhoneInventoryID("phone:canonical"))
        XCTAssertFalse(OrbitDeviceReconciler.isPhoneInventoryID("bluetooth:mouse"))
        let rows = [BatteryMenuDevice(id: "phone:canonical", name: "Study iPad", symbol: "ipad", detail: "Charging", level: 44),
            BatteryMenuDevice(id: "raw-bluetooth", name: "Study iPad", symbol: "headphones", detail: "Battery unavailable", level: 90)]
        let result = OrbitDeviceReconciler.menuRows(rows, combine: true, at: Date())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].symbol, "ipad")
        XCTAssertEqual(result[0].level, 44)
        XCTAssertEqual(result[0].detail, "Charging")
    }
    private func reading(plugged: Bool = true, charging: Bool = true, current: Int = 2000, input: Int? = 48000) -> [String: Any] {
        var result: [String: Any] = ["CurrentCapacity": 62, "ExternalConnected": plugged,
            "IsCharging": charging, "Voltage": 12000, "Amperage": current,
            "AdapterDetails": ["Watts": 65]]
        if let input { result["PowerTelemetryData"] = ["SystemPowerIn": input] }
        return result
    }
    func testInputIsMeasuredNotAdapterRatingAndBalancesCharge() {
        let value = BatteryMenuSnapshot.parse(reading(), lowPower: false)
        XCTAssertEqual(value.inputWatts, 48)
        XCTAssertEqual(value.adapterRating, 65)
        XCTAssertEqual(value.batteryWatts, 24)
        XCTAssertEqual(value.systemWatts, 24)
        XCTAssertEqual(value.state, "Charging")
    }
    func testBatteryCanSupplementAWeakCharger() {
        let value = BatteryMenuSnapshot.parse(reading(charging: false, current: -1000, input: 5000), lowPower: false)
        XCTAssertEqual(value.batteryWatts, -12)
        XCTAssertEqual(value.systemWatts, 17)
        XCTAssertEqual(value.state, "Battery helping the charger")
        XCTAssertEqual(value.batteryFlow, "From the battery")
    }
    func testUnpluggedIgnoresStaleAdapterTelemetry() {
        let value = BatteryMenuSnapshot.parse(reading(plugged: false, charging: false, current: -1000), lowPower: false)
        XCTAssertNil(value.inputWatts)
        XCTAssertEqual(value.systemWatts, 12)
        XCTAssertEqual(value.state, "On battery")
    }
    func testMissingTelemetryNeverUsesChargerCapacityAsInput() {
        let value = BatteryMenuSnapshot.parse(reading(input: nil), lowPower: false)
        XCTAssertEqual(value.adapterRating, 65)
        XCTAssertNil(value.inputWatts)
        XCTAssertNil(value.systemWatts)
    }
    func testMissingCurrentAndInvalidPowerStayUnavailable() {
        var data = reading(); data.removeValue(forKey: "Amperage")
        let value = BatteryMenuSnapshot.parse(data, lowPower: false)
        XCTAssertNil(value.batteryWatts)
        XCTAssertNil(value.systemWatts)
        XCTAssertNil(BatteryMenuSnapshot.validWatts(.nan))
        XCTAssertNil(BatteryMenuSnapshot.validWatts(.infinity))
        XCTAssertNil(BatteryMenuSnapshot.validWatts(1000))
    }
    func testIdleAndInconsistentSamplesAreNotChargingDraw() {
        var data = reading(charging: false, current: 0, input: 18000); data["FullyCharged"] = true
        let full = BatteryMenuSnapshot.parse(data, lowPower: false)
        XCTAssertEqual(full.state, "Fully charged")
        XCTAssertEqual(full.systemWatts, 18)
        XCTAssertEqual(full.batteryFlow, "Battery resting")
        XCTAssertNil(BatteryMenuSnapshot.parse(reading(current: 2000, input: 5000), lowPower: false).systemWatts)
    }
    func testUnknownBatteryDoesNotBecomeAnInventedPercentage() {
        let value = BatteryMenuSnapshot.parse([:], lowPower: false)
        XCTAssertNil(value.level)
        XCTAssertNil(value.health)
        XCTAssertNil(value.volts)
        XCTAssertNil(value.systemWatts)
        XCTAssertEqual(BatteryMenuSnapshot.watts(nil), "—")
    }
    @MainActor func testIconsAreOriginalColourAndHaveCompactBounds() {
        for level in [0, 1, 19, 20, 50, 99, 100] {
            let image = BatteryMenuIcon.image(level: level, charging: false, lowPower: false, color: true, percentage: true)
            XCTAssertFalse(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 34, height: 17))
            XCTAssertNotNil(image.tiffRepresentation)
        }
        for level in [1, 9, 20, 50, 75, 100] {
            for coloured in [true, false] {
                let charging = BatteryMenuIcon.image(level: level, charging: true, lowPower: false, color: coloured, percentage: true)
                XCTAssertEqual(charging.size, NSSize(width: 38, height: 17))
                XCTAssertNotNil(charging.tiffRepresentation)
                XCTAssertTrue(charging.accessibilityDescription?.contains("charging") == true)
            }
        }
        XCTAssertEqual(BatteryMenuIcon.tint(level: 8, charging: true, lowPower: true), .systemGreen)
        XCTAssertEqual(BatteryMenuIcon.tint(level: 80, charging: false, lowPower: true), .systemYellow)
        XCTAssertEqual(BatteryMenuIcon.tint(level: 80, charging: true, lowPower: false), .systemGreen)
    }
}
