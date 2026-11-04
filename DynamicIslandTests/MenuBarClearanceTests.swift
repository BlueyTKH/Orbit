import XCTest
import SwiftUI
import Combine
@testable import NotchFlow

/// The screen these use is a 14" MacBook Pro: 1710pt wide, notch 185pt wide and
/// centred, so the menu bar's left strip runs 0...762.5.
final class MenuBarClearanceTests: XCTestCase {
    func testTimerCountdownWidthUsesTextAndRetainsInnerClearance() {
        XCTAssertEqual(TimerWingGeometry.countdownWidth(measured: 31), 40)
        XCTAssertEqual(TimerWingGeometry.countdownWidth(measured: 40), 48)
        XCTAssertEqual(TimerWingGeometry.countdownWidth(measured: 80), 88)
        for width: CGFloat in [0, 31, 40, 80, 120] {
            XCTAssertGreaterThanOrEqual(TimerWingGeometry.countdownWidth(measured: width), width + 8)
        }
    }

    func testActiveTimerCannotBeConstrainedByBackgroundRecordingWidth() {
        for state in [false, true] {
            let layout = makeRecordingHUDLayout(notchState: .closed,
                screenRecordingDetectionEnabled: true, showRecordingIndicator: true,
                hideOnClosed: false, isRecording: true, closedMusicPairingEligible: false,
                recordingControlMode: .withStopButton, canStopFromHUD: true,
                recordingHoverStyle: .default, expanded: false, foregroundTimerActive: state)
            XCTAssertEqual(layout.isVisible, !state)
            XCTAssertEqual(layout.size(closedNotchSize: CGSize(width: 179, height: 32),
                effectiveClosedNotchHeight: 32) == nil, state)
        }
    }

    func testFinishedTimerPopupKeepsCameraLaneAndCompactContent() {
        for closed in [CGSize(width: 179, height: 32), CGSize(width: 185, height: 30)] {
            let size = TimerFinishedPopup.size(closed: closed)
            XCTAssertGreaterThanOrEqual(size.width, closed.width)
            XCTAssertEqual(size.height - closed.height, 68)
            XCTAssertLessThan(size.width, 400)
            XCTAssertLessThan(size.height, 110)
        }
    }

    @MainActor
    func testIdleMousePollingDoesNotRepublishUnchangedSnapshotsAndKeepsRealUpdates() {
        let manager = AccessoryConnectionManager() // No polling/hardware starts in init.
        var changes = 0
        let subscription = manager.$connectedMice.dropFirst().sink { _ in changes += 1 }
        var first = AccessoryConnectionEvent(address: "A", name: "Mouse", symbol: "computermouse.fill", kind: .mouse,
            connected: true, main: nil)
        let second = AccessoryConnectionEvent(address: "B", name: "Mouse", symbol: "computermouse.fill", kind: .mouse,
            connected: true, main: 80)
        for index in 0..<10_000 {
            manager.updateConnectedMice(index.isMultiple(of: 2) ? [first, second] : [second, first])
        }
        XCTAssertEqual(changes, 1, "Stable one-second polls must not rebuild Settings or change equal-name ordering")
        XCTAssertEqual(manager.connectedMice.map(\.address), ["A", "B"])
        first.main = 0 // Late measured zero is still a real reading.
        manager.updateConnectedMice([second, first])
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(manager.connectedMice.first?.main, 0)
        manager.updateConnectedMice([second])
        XCTAssertEqual(changes, 3, "A real disconnection must still publish immediately")
        manager.updateConnectedMice([])
        manager.updateConnectedMice([])
        XCTAssertEqual(changes, 4)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testClosedSettingsReleasesHostingGraphAndKeepsNavigation() async {
        let navigation = SettingsNavigationState()
        navigation.selectedTabID = "devices"
        navigation.searchText = "mouse"
        let controller = SettingsWindowController(navigationState: navigation)
        weak var oldHost: NSView?
        autoreleasepool {
            controller.prepareSettingsContent()
            oldHost = controller.window?.contentView
            XCTAssertNotNil(oldHost)
            controller.releaseSettingsContent()
        }
        for _ in 0..<10 {
            if oldHost == nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(oldHost, "A closed Settings window must release its tasks and subscriptions with the hosting graph")
        controller.prepareSettingsContent()
        XCTAssertEqual(navigation.selectedTabID, "devices")
        XCTAssertEqual(navigation.searchText, "mouse")
        XCTAssertNotNil(controller.window?.contentView)
        controller.releaseSettingsContent()
    }

    @MainActor
    func testRepeatedSettingsLifetimesDoNotKeepEarlierHostingViews() async {
        let navigation = SettingsNavigationState()
        navigation.selectedTabID = "about"
        let controller = SettingsWindowController(navigationState: navigation)
        let hosts = NSHashTable<NSView>.weakObjects()
        for _ in 0..<20 {
            autoreleasepool {
                controller.prepareSettingsContent()
                if let host = controller.window?.contentView { hosts.add(host) }
                controller.releaseSettingsContent()
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosts.allObjects.count, 0, "Each close must release the prior graph, rather than accumulating hidden forms")
    }

    func testAirPodsWarningsIdentifyLowerSideAndGroupWithinFivePoints() {
        var reading = AirPodsBatteryReading(address: "AA", name: "AirPods", symbol: "airpods", left: 15, right: 50, main: nil, observedAt: Date())
        XCTAssertEqual(reading.lowSide, .left)
        XCTAssertEqual(reading.lowSide.compactTitle, "Left AirPod")
        reading.left = 50; reading.right = 10
        XCTAssertEqual(reading.lowSide, .right)
        reading.left = 15; reading.right = 20
        XCTAssertEqual(reading.lowSide, .together)
        reading.right = 21
        XCTAssertEqual(reading.lowSide, .left)
        reading.leftCharging = true
        XCTAssertEqual(reading.lowSide, .right)
        reading.left = nil; reading.right = nil; reading.main = 10
        XCTAssertEqual(reading.lowSide, .device)
    }
    func testAirPodsWarningPreviewPreservesTheRealEarbudImbalance() {
        let reading = AirPodsBatteryReading(address: "AA", name: "AirPods", symbol: "airpods", left: 90, right: 50, main: nil, observedAt: Date())
        let preview = reading.previewing(level: 10)
        XCTAssertEqual(preview.left, 50); XCTAssertEqual(preview.right, 10)
        XCTAssertEqual(preview.lowSide, .right)
        XCTAssertEqual(reading.left, 90); XCTAssertEqual(reading.right, 50)
        let maxReading = AirPodsBatteryReading(address: "BB", name: "AirPods Max", symbol: "airpodsmax", left: nil, right: nil, main: 60, observedAt: Date())
        XCTAssertEqual(maxReading.previewing(level: 5).main, 5)
        XCTAssertNil(maxReading.previewing(level: 5).left)
    }
    func testAirPodsWarningMigrationPreservesCustomizedSettings() {
        let warnings = AirPodsWarningConfiguration.initial(threshold: 18, duration: 7, style: .standard, sound: false)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.percentage, 18)
        XCTAssertEqual(warnings.first?.duration, 7)
        XCTAssertEqual(warnings.first?.presentation, .expanded)
        XCTAssertEqual(warnings.first?.sound, false)
    }
    func testAirPodsWarningListRejectsScreenGlowAndDuplicateThresholds() {
        let warnings = AirPodsWarningConfiguration.normalized([
            LowBatteryWarning(percentage: 5, duration: 100, presentation: .critical),
            LowBatteryWarning(percentage: 5), LowBatteryWarning(percentage: 0),
            LowBatteryWarning(percentage: 10, enabled: false)])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.presentation, .expanded)
        XCTAssertEqual(warnings.first?.duration, 60)
    }
    func testMultipleAirPodsWarningsFireOnceAndSkipHigherLevelsOnLargeDrop() throws {
        let now = Date()
        let warnings = [LowBatteryWarning(percentage: 20), LowBatteryWarning(percentage: 10), LowBatteryWarning(percentage: 5)]
        var tracker = AirPodsBatteryWarningTracker()
        var reading = AirPodsBatteryReading(address: "AA:BB", name: "AirPods", symbol: "airpods", left: 19, right: 100, main: nil, observedAt: now)
        XCTAssertEqual(tracker.nextWarning(reading, warnings: warnings, now: now)?.percentage, 20)
        tracker.markDelivered(reading, warnings: warnings, now: now)
        XCTAssertNil(tracker.nextWarning(reading, warnings: warnings, now: now))
        reading.left = 4
        XCTAssertEqual(tracker.nextWarning(reading, warnings: warnings, now: now)?.percentage, 5)
        tracker.markDelivered(reading, warnings: warnings, now: now)
        XCTAssertNil(tracker.nextWarning(reading, warnings: warnings, now: now))
        XCTAssertEqual(tracker.delivered.count, 3)
        reading.left = 13
        for warning in warnings { tracker.recover(reading, threshold: warning.percentage, now: now) }
        XCTAssertEqual(tracker.delivered, [AirPodsBatteryWarningTracker.key(address: reading.address, threshold: 20)])
        reading.left = 10
        XCTAssertEqual(tracker.nextWarning(reading, warnings: warnings, now: now)?.percentage, 10)
        reading.leftCharging = true
        XCTAssertNil(tracker.nextWarning(reading, warnings: warnings, now: now))
    }
    func testAirPodsConnectionKeepsSeparateLevelsAndDisconnectionSnapshot() {
        let reading = AirPodsBatteryReading(address: "AA", name: "AirPods", symbol: "airpods", left: 50, right: 100, main: nil, observedAt: Date())
        let event = AccessoryConnectionEvent(address: "AA", name: "AirPods", symbol: "airpods", kind: .airPods, connected: true).updating(reading)
        XCTAssertEqual(event.left, 50); XCTAssertEqual(event.right, 100)
        XCTAssertEqual(event.detail, "Left 50%  ·  Right 100%")
        let disconnected = AccessoryConnectionEvent(address: event.address, name: event.name, symbol: event.symbol, kind: .airPods,
            connected: false, left: event.left, right: event.right)
        XCTAssertEqual(disconnected.status, "Disconnected")
        XCTAssertEqual(disconnected.detail, "Last reported: Left 50%  ·  Right 100%")
        let wrong = AirPodsBatteryReading(address: "BB", name: "AirPods", symbol: "airpods", left: 1, right: 1, main: nil, observedAt: Date())
        XCTAssertEqual(event.updating(wrong), event)
    }
    func testAirPodsArtworkMatchesModelAndRetainsExplicitProThirdIdentity() {
        XCTAssertEqual(AirPodsArtworkModel.resolve(symbol: "airpods.gen4", name: "My earbuds"), .fourth)
        XCTAssertEqual(AirPodsArtworkModel.resolve(symbol: "airpods.gen3", name: "My earbuds"), .third)
        XCTAssertEqual(AirPodsArtworkModel.resolve(symbol: "airpods.pro", name: "AirPods Pro 3"), .proThird)
        XCTAssertEqual(AirPodsArtworkModel.resolve(symbol: "airpods.pro", name: "AirPods Pro"), .pro)
        XCTAssertEqual(AirPodsArtworkModel.resolve(symbol: "airpodsmax", name: "My headphones"), .max)
        let event = AccessoryConnectionEvent(address: "A", name: "My earbuds", symbol: "airpods.pro", kind: .airPods,
            connected: true, artworkModel: .proThird)
        let reading = AirPodsBatteryReading(address: "A", name: "My earbuds", symbol: "airpods.pro", left: 50,
            right: 90, main: nil, observedAt: Date())
        XCTAssertEqual(event.updating(reading).artworkModel, .proThird)
    }
    func testAirPodsArtworkAtlasesContainAllFramesAtExpectedResolution() throws {
        for model in AirPodsArtworkModel.allCases where model != .max {
            let image = try XCTUnwrap(NSImage(named: model.assetName), model.rawValue)
            let atlas = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(atlas.width, 192 * 8)
            XCTAssertEqual(atlas.height, 258 * 8)
        }
    }
    func testAirPodsArtworkSlowPlaybackEndpointsAndReverseAreBounded() {
        XCTAssertEqual(AirPodsArtworkModel.frame(elapsed: -1, connected: true), 0)
        XCTAssertEqual(AirPodsArtworkModel.frame(elapsed: 0, connected: false), 63)
        XCTAssertEqual(AirPodsArtworkModel.frame(elapsed: AirPodsArtworkModel.duration / 2, connected: true), 31)
        XCTAssertEqual(AirPodsArtworkModel.frame(elapsed: AirPodsArtworkModel.duration / 2, connected: false), 32)
        XCTAssertEqual(AirPodsArtworkModel.frame(elapsed: 99, connected: true), 63)
        XCTAssertEqual(AirPodsArtworkModel.frame(elapsed: 99, connected: false), 0)
    }
    func testMouseCountdownWaitsForBatteryThenStartsOnceForFullConfiguredDuration() {
        var delayed = MouseBatteryPresentationClock(duration: 2, hasBattery: false)
        XCTAssertTrue(delayed.waitingForBattery)
        XCTAssertTrue(delayed.initialHideDelay.isInfinite)
        XCTAssertEqual(delayed.resolveBattery(), 2)
        XCTAssertFalse(delayed.waitingForBattery)
        XCTAssertNil(delayed.resolveBattery(), "Subsequent battery changes must not restart the timer")
        var ready = MouseBatteryPresentationClock(duration: 2, hasBattery: true)
        XCTAssertEqual(ready.initialHideDelay, 2)
        XCTAssertNil(ready.resolveBattery())
        XCTAssertEqual(MouseBatteryPresentationClock(duration: 0, hasBattery: true).initialHideDelay, 1)
        XCTAssertEqual(MouseBatteryPresentationClock(duration: 100, hasBattery: true).initialHideDelay, 60)
    }
    func testMouseUnavailableFallbackStartsConfiguredReadTimeWithoutStayingForever() {
        var clock = MouseBatteryPresentationClock(duration: 4, hasBattery: false)
        XCTAssertEqual(MouseBatteryPresentationClock.unavailableTimeout, 15)
        XCTAssertEqual(clock.resolveUnavailable(), 4)
        XCTAssertNil(clock.resolveUnavailable())
        // If a late first reading appears while the unavailable card is still
        // visible, the user must still receive its entire measured read time.
        XCTAssertEqual(clock.resolveBattery(), 4)
        XCTAssertNil(clock.resolveBattery())
        XCTAssertNil(clock.resolveUnavailable())
    }
    func testMouseConnectionEdgesStaySilentAtStartupAndDeduplicateNativeAndPollSignals() {
        var presence = MouseConnectionPresence()
        XCTAssertTrue(presence.arrivals(in: ["existing"]).isEmpty)
        XCTAssertEqual(presence.arrivals(in: ["existing", "mouse"]), ["mouse"])
        XCTAssertTrue(presence.arrivals(in: ["existing", "mouse"]).isEmpty)
        presence.disconnected("mouse")
        // A reconnect entirely between fallback polls is still a new edge.
        XCTAssertEqual(presence.arrivals(in: ["existing", "mouse"]), ["mouse"])
        presence.resetBaseline()
        XCTAssertTrue(presence.arrivals(in: ["existing", "mouse", "connected-while-locked"]).isEmpty)
    }
    func testMouseSystemPowerSnapshotUsesFreshCapacityAndRejectsInvalidSources() {
        func source(_ name: String, _ current: Any, _ maximum: Any = 100) -> [String: Any] {
            ["Type": "Accessory Source", "Name": name, "Current Capacity": current, "Max Capacity": maximum]
        }
        var absent = source("Absent", 50); absent["Is Present"] = false
        var internalBattery = source("Mac", 90); internalBattery["Type"] = "InternalBattery"
        let readings = AccessorySystemPowerSource.decode([
            source("Mouse", 97), source("Empty", 0), source("Scaled", 100, 200),
            source("Invalid", 255), source("Negative", -1), source("ZeroMax", 1, 0),
            source("Boolean", true), absent, internalBattery,
            source("Duplicate", 10), source("Duplicate", 20)
        ])
        XCTAssertEqual(readings["Mouse"], [97])
        XCTAssertEqual(readings["Empty"], [0])
        XCTAssertEqual(readings["Scaled"], [50])
        for name in ["Invalid", "Negative", "ZeroMax", "Boolean", "Absent", "Mac"] { XCTAssertNil(readings[name]) }
        XCTAssertNil(AccessoryPowerReadings.level(name: "Duplicate", connectedNames: ["Duplicate"], readings: readings))
        // An empty early snapshot does not hide a reading published just after it.
        XCTAssertTrue(AccessorySystemPowerSource.decode([]).isEmpty)
        XCTAssertEqual(AccessorySystemPowerSource.decode([source("Mouse", 96)])["Mouse"], [96])
    }
    func testMouseReadingSurvivesMacRomanNameInAnotherAccessory() throws {
        let report = " -Kay Hsen’s AirPods (id=1)\t56%; discharging present: true\n -Inphic BT Mouse (id=2)\t98%; \n"
        let data = try XCTUnwrap(report.data(using: .macOSRoman))
        XCTAssertNil(String(data: data, encoding: .utf8))
        XCTAssertEqual(AccessoryPowerReadings.parse(data)["Inphic BT Mouse"], [98])
        XCTAssertEqual(AccessoryPowerReadings.parse(data)["Kay Hsen’s AirPods"], [56])
    }
    func testMousePowerReadingAcceptsRealReportAndRejectsAmbiguityAndSentinels() {
        let report = "Now drawing from 'AC Power'\n -Inphic BT Mouse (id=42210195)\t98%; \n -Other Mouse (id=3)\t1%; discharging present: true\n -Invalid Mouse (id=4)\t255%; \n"
        let readings = AccessoryPowerReadings.parse(report)
        XCTAssertEqual(AccessoryPowerReadings.level(name: "Inphic BT Mouse", connectedNames: ["Inphic BT Mouse"], readings: readings), 98)
        XCTAssertEqual(readings["Other Mouse"], [1])
        XCTAssertNil(readings["Invalid Mouse"])
        XCTAssertNil(AccessoryPowerReadings.level(name: "Inphic BT Mouse", connectedNames: ["Inphic BT Mouse", "Inphic BT Mouse"], readings: readings))
        XCTAssertNil(AccessoryPowerReadings.level(name: "missing", connectedNames: ["missing"], readings: readings))
        XCTAssertEqual(AccessoryConnectionEvent.mousePreview.detail, "98%")
    }
    func testAccessoryHUDSizesStayCameraSafeInsidePreviewCanvas() {
        let closed = CGSize(width: 179, height: 32)
        XCTAssertEqual(AccessoryConnectionLayout.surface(closed: closed, style: .compact), CGSize(width: 435, height: 32))
        XCTAssertEqual(AccessoryConnectionLayout.surface(closed: closed, style: .standard), CGSize(width: 369, height: 120))
        for style in [BatteryNotificationStyle.compact, .standard] {
            let surface = AccessoryConnectionLayout.surface(closed: closed, style: style)
            let canvas = BatteryPreviewLayout.canvas(surface: surface, opened: CGSize(width: 640, height: 200))
            XCTAssertGreaterThanOrEqual(canvas.width, surface.width)
            XCTAssertGreaterThanOrEqual(canvas.height, surface.height)
        }
    }

    func testRealExpandedBatteryCanvasContainsTheEntireFullAndLowCard() {
        let closed = CGSize(width: 179, height: 32)
        for (kind, card, oldWidth) in [
            (BatteryTemporaryHUDKind.fullBattery, CGSize(width: 319, height: 102), CGFloat(259)),
            (.lowBattery, CGSize(width: 329, height: 107), CGFloat(279))
        ] {
            let canvas = BatteryTemporaryHUDLayout.surface(kind: kind, style: .standard, closed: closed)
            let cardFrame = CGRect(x: (canvas.width - card.width) / 2, y: 0, width: card.width, height: card.height)
            XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(cardFrame), "Real alerts need rounded ends outside the old window width")
            XCTAssertLessThan(oldWidth, card.width, "Reproduce the pre-fix window clipping independently of preview reservation")
            XCTAssertEqual(canvas, card)
        }
    }

    func testSharedBatterySurfacePreservesCompactAndOtherPowerEventDimensions() {
        for closed in [CGSize(width: 179, height: 32), CGSize(width: 185, height: 30)] {
            for kind in [BatteryTemporaryHUDKind.charging, .unplugged, .lowBattery, .fullBattery, .lowPowerEnabled, .lowPowerDisabled] {
                XCTAssertEqual(BatteryTemporaryHUDLayout.surface(kind: kind, style: .compact, closed: closed),
                    CGSize(width: closed.width + 180, height: closed.height))
            }
            for kind in [BatteryTemporaryHUDKind.charging, .unplugged, .lowPowerEnabled, .lowPowerDisabled] {
                XCTAssertEqual(BatteryTemporaryHUDLayout.surface(kind: kind, style: .standard, closed: closed),
                    CGSize(width: closed.width + 190, height: closed.height + 70))
            }
        }
    }

    func testBatteryPreviewCanvasRetainsExpandedCardsRoundedEdges() {
        let card = CGSize(width: 329, height: 107)
        let oldCanvas = CGSize(width: 279, height: 107)
        XCTAssertLessThan(oldCanvas.width, card.width)
        let previewCanvas = BatteryPreviewLayout.canvas(surface: card, opened: CGSize(width: 640, height: 200))
        XCTAssertEqual(previewCanvas, CGSize(width: 640, height: 200))
        let cardFrame = CGRect(x: (previewCanvas.width - card.width) / 2, y: 0, width: card.width, height: card.height)
        XCTAssertTrue(CGRect(origin: .zero, size: previewCanvas).contains(cardFrame))
        let larger = BatteryPreviewLayout.canvas(surface: CGSize(width: 700, height: 260), opened: CGSize(width: 640, height: 200))
        XCTAssertEqual(larger, CGSize(width: 700, height: 260))
    }

    func testAirPodsLowestEarbudIsNotMaskedByFullCaseOrOtherBud() throws {
        let reading = try XCTUnwrap(AirPodsBatteryReading.decode(["BatteryPercentLeft": 15, "BatteryPercentRight": 80, "BatteryPercentCase": 100],
            address: "AA:BB", name: "AirPods Pro", symbol: "airpods.pro", observedAt: Date()))
        XCTAssertEqual(reading.listeningLevel, 15)
        XCTAssertEqual(reading.detail, "Left 15%  ·  Right 80%")
    }
    func testAirPodsOnePercentAndUnknownSentinelsAreHandledCorrectly() throws {
        XCTAssertEqual(AirPodsBatteryReading.percentage(1), 1)
        XCTAssertEqual(AirPodsBatteryReading.percentage("1%"), 1)
        XCTAssertEqual(AirPodsBatteryReading.percentage("100%"), 100)
        XCTAssertEqual(AirPodsBatteryReading.percentage(0), 0)
        for value: Any in [255, -1, true, Double.nan, "Unknown", 0.8] { XCTAssertNil(AirPodsBatteryReading.percentage(value)) }
        XCTAssertNil(AirPodsBatteryReading.decode(["BatteryPercentCase": 5], address: "A", name: "AirPods", symbol: "airpods", observedAt: Date()))
    }
    func testAirPodsChargingEarbudIsExcludedButDischargingBudStillWarns() throws {
        let reading = try XCTUnwrap(AirPodsBatteryReading.decode(["BatteryPercentLeft": 1, "BatteryPercentRight": 15, "BatteryIsChargingLeft": true],
            address: "A", name: "AirPods", symbol: "airpods", observedAt: Date()))
        XCTAssertEqual(reading.listeningLevel, 15)
    }
    func testAirPodsMaxSingleBatteryAndChargingState() throws {
        let reading = try XCTUnwrap(AirPodsBatteryReading.decode(["BatteryPercentSingle": 8, "BatteryIsCharging": true],
            address: "A", name: "AirPods Max", symbol: "airpodsmax", observedAt: Date()))
        XCTAssertNil(reading.listeningLevel)
        XCTAssertEqual(reading.recoveryLevel, 8)
    }
    func testAirPodsProfilerFieldsKeepSeparateEarbuds() throws {
        let reading = try XCTUnwrap(AirPodsBatteryReading.decode(["device_batteryLevelLeft": "12%", "device_batteryLevelRight": "26%", "device_batteryLevelCase": "80%"],
            address: "A", name: "AirPods", symbol: "airpods", observedAt: Date()))
        XCTAssertEqual(reading.listeningLevel, 12)
    }
    func testAirPodsWarningOncePerChargeCycleAcrossReconnectAndRestart() {
        let now = Date()
        var reading = AirPodsBatteryReading(address: "AA:BB", name: "AirPods", symbol: "airpods", left: 20, right: 24, main: nil, observedAt: now)
        var tracker = AirPodsBatteryWarningTracker()
        XCTAssertTrue(tracker.shouldWarn(reading, threshold: 20, now: now))
        tracker.markDelivered(reading, threshold: 20)
        tracker = AirPodsBatteryWarningTracker(delivered: tracker.delivered)
        XCTAssertFalse(tracker.shouldWarn(reading, threshold: 20, now: now))
        reading.left = 22; tracker.recover(reading, threshold: 20, now: now)
        XCTAssertFalse(tracker.delivered.isEmpty)
        reading.left = 23; tracker.recover(reading, threshold: 20, now: now)
        XCTAssertTrue(tracker.delivered.isEmpty)
        reading.left = 19; XCTAssertTrue(tracker.shouldWarn(reading, threshold: 20, now: now))
    }
    func testAirPodsDevicesAndThresholdChangesAreIndependent() {
        let now = Date()
        let a = AirPodsBatteryReading(address: "AA:BB", name: "A", symbol: "airpods", left: 15, right: 16, main: nil, observedAt: now)
        let b = AirPodsBatteryReading(address: "CC:DD", name: "B", symbol: "airpods", left: 10, right: nil, main: nil, observedAt: now)
        var tracker = AirPodsBatteryWarningTracker(); tracker.markDelivered(a, threshold: 20)
        XCTAssertTrue(tracker.shouldWarn(b, threshold: 20, now: now))
        XCTAssertFalse(tracker.shouldWarn(a, threshold: 10, now: now))
        XCTAssertEqual(AirPodsBatteryWarningTracker.key(address: "AA-BB", threshold: 20), AirPodsBatteryWarningTracker.key(address: "aa:bb", threshold: 20))
    }
    func testAirPodsStaleAndFutureReadingsNeverGenerateWarnings() {
        let now = Date()
        let reading = AirPodsBatteryReading(address: "A", name: "AirPods", symbol: "airpods", left: 5, right: nil, main: nil, observedAt: now)
        let tracker = AirPodsBatteryWarningTracker()
        XCTAssertFalse(tracker.shouldWarn(reading, threshold: 20, now: now.addingTimeInterval(66)))
        XCTAssertFalse(tracker.shouldWarn(reading, threshold: 20, now: now.addingTimeInterval(-1)))
    }
    func testAirPodsLayoutsReserveCameraAndExpandedCardWithinPreviewCanvas() {
        let closed = CGSize(width: 179, height: 32)
        XCTAssertEqual(AirPodsBatteryWarningLayout.surface(closed: closed, style: .compact), CGSize(width: 359, height: 32))
        let expanded = AirPodsBatteryWarningLayout.surface(closed: closed, style: .standard)
        XCTAssertEqual(expanded, CGSize(width: 329, height: 107))
        let canvas = BatteryPreviewLayout.canvas(surface: expanded, opened: CGSize(width: 640, height: 200))
        XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(CGRect(origin: .zero, size: expanded)))
    }
    func testAirPodsNativePopupRecognizesUserNameAliasForSameAddress() {
        let now = Date()
        let reading = AirPodsBatteryReading(address: "AA:BB", name: "AirPods 4 (ANC)", symbol: "airpods.gen4", left: 10, right: 35, main: nil, observedAt: now)
        let texts = ["Kay Hsen’s AirPods", "Low Battery", "10%"]
        XCTAssertNil(AirPodsNativeLowBatteryMatcher.match(owner: "com.apple.controlcenter", texts: texts, width: 300, height: 80,
            readings: [reading], labels: ["Low Battery"], now: now))
        XCTAssertNotNil(AirPodsNativeLowBatteryMatcher.match(owner: "com.apple.controlcenter", texts: texts, width: 300, height: 80,
            readings: [reading], labels: ["Low Battery"], aliases: [reading.address: ["Kay Hsen’s AirPods"]], now: now))
        XCTAssertNil(AirPodsNativeLowBatteryMatcher.match(owner: "com.apple.controlcenter", texts: texts, width: 300, height: 80,
            readings: [reading], labels: ["Low Battery"], aliases: ["other-address": ["Kay Hsen’s AirPods"]], now: now))
        let other = AirPodsBatteryReading(address: "CC:DD", name: "Other AirPods", symbol: "airpods", left: 10, right: 35, main: nil, observedAt: now)
        XCTAssertNil(AirPodsNativeLowBatteryMatcher.match(owner: "com.apple.controlcenter", texts: texts, width: 300, height: 80,
            readings: [reading, other], labels: ["Low Battery"], aliases: [reading.address: ["Kay Hsen’s AirPods"], other.address: ["Kay Hsen’s AirPods"]], now: now))
    }
    func testNativeDuplicateCanBeDismissedWhileAnotherNotchViewIsOpen() {
        let now = Date()
        XCTAssertEqual(AirPodsNativeWarningReplayPolicy.action(delivered: true, hasMeasuredReading: true,
            lastPresentation: nil, canPresent: false, now: now), .dismissDuplicate)
        XCTAssertEqual(AirPodsNativeWarningReplayPolicy.action(delivered: false, hasMeasuredReading: true,
            lastPresentation: nil, canPresent: false, now: now), .queueAndDismiss)
        XCTAssertEqual(AirPodsNativeWarningReplayPolicy.action(delivered: false, hasMeasuredReading: true,
            lastPresentation: nil, canPresent: true, now: now), .presentAndDismiss)
        XCTAssertEqual(AirPodsNativeWarningReplayPolicy.action(delivered: false, hasMeasuredReading: false,
            lastPresentation: now, canPresent: false, now: now), .dismissDuplicate)
    }
    func testAirPodsNativePopupMatcherRejectsConnectionsCaseWarningsAndUnrelatedApps() {
        let now = Date(); let reading = AirPodsBatteryReading(address: "A", name: "Kay’s AirPods Pro", symbol: "airpods.pro", left: 10, right: 12, main: nil, observedAt: now)
        func match(_ owner: String, _ texts: [String], height: CGFloat = 80) -> AirPodsBatteryReading? {
            AirPodsNativeLowBatteryMatcher.match(owner: owner, texts: texts, width: 300, height: height, readings: [reading], labels: ["Low Battery"], now: now)
        }
        XCTAssertNotNil(match("com.apple.controlcenter", [reading.name, "Low Battery", "10% "]))
        XCTAssertNil(match("com.apple.controlcenter", [reading.name, "Connected", "10% "]))
        XCTAssertNil(match("com.apple.controlcenter", [reading.name, "Case Low Battery", "10% "]))
        XCTAssertNil(match("com.apple.controlcenter", ["Other AirPods", "Low Battery"]))
        XCTAssertNil(match("com.apple.controlcenter", [reading.name, "Low Battery"], height: 400))
        XCTAssertNil(match("com.apple.notificationcenterui", [reading.name, "Low Battery"]))
        XCTAssertNil(match("com.example.mail", [reading.name, "Low Battery"]))
    }
    func testAirPodsNativePopupMatcherSupportsRenamedDevicesAndLocalizedLowBatteryLabel() {
        let now = Date(); let reading = AirPodsBatteryReading(address: "A", name: "My earbuds", symbol: "airpods", left: 5, right: nil, main: nil, observedAt: now)
        XCTAssertNotNil(AirPodsNativeLowBatteryMatcher.match(owner: "com.apple.controlcenter", texts: [reading.name, "Batterie faible"],
            width: 300, height: 80, readings: [reading], labels: ["Batterie faible"], now: now))
        XCTAssertNil(AirPodsNativeLowBatteryMatcher.match(owner: "com.apple.controlcenter", texts: [reading.name, "Batterie faible"],
            width: 300, height: 80, readings: [reading], labels: ["Batterie faible"], now: now.addingTimeInterval(70)))
    }

    func testAirPodsNativeRingIsLiveSourceWhenCacheIsHigherOrUnknown() throws {
        let now = Date()
        let old = AirPodsBatteryReading(address: "A", name: "AirPods", symbol: "airpods", left: 25, right: 30, main: nil, observedAt: now)
        let live = try XCTUnwrap(AirPodsNativeLowBatteryMatcher.readingFromPopup(old, texts: ["AirPods", "Low Battery", "10"], now: now))
        XCTAssertEqual(live.listeningLevel, 10)
        XCTAssertNil(live.left) // Do not invent which bud the native ring represents.
        let unknown = AirPodsBatteryReading(address: "A", name: "AirPods", symbol: "airpods", left: nil, right: nil, main: nil, observedAt: now)
        XCTAssertEqual(AirPodsNativeLowBatteryMatcher.readingFromPopup(unknown, texts: ["1%"], now: now)?.listeningLevel, 1)
        XCTAssertNil(AirPodsNativeLowBatteryMatcher.readingFromPopup(unknown, texts: ["AirPods Pro 3", "Unknown"], now: now))
        XCTAssertNil(AirPodsNativeLowBatteryMatcher.readingFromPopup(unknown, texts: ["83%"], now: now))
    }
    func testAirPodsNativePopupSameNamesAreAmbiguous() {
        let now = Date()
        let first = AirPodsBatteryReading(address: "A", name: "AirPods", symbol: "airpods", left: 10, right: nil, main: nil, observedAt: now)
        let second = AirPodsBatteryReading(address: "B", name: "AirPods", symbol: "airpods", left: 5, right: nil, main: nil, observedAt: now)
        XCTAssertNil(AirPodsNativeLowBatteryMatcher.match(owner: "com.apple.controlcenter", texts: ["AirPods", "Low Battery"],
            width: 300, height: 80, readings: [first, second], labels: ["Low Battery"], now: now))
    }

    func testAirPodsNativeOnlyWarningsRemainAvailableWithoutMeasuredRecovery() {
        let now = Date()
        XCTAssertFalse(AirPodsNativeWarningReplayPolicy.shouldPresent(delivered: true, hasMeasuredReading: true, lastPresentation: nil, now: now))
        XCTAssertTrue(AirPodsNativeWarningReplayPolicy.shouldPresent(delivered: true, hasMeasuredReading: false, lastPresentation: nil, now: now))
        XCTAssertFalse(AirPodsNativeWarningReplayPolicy.shouldPresent(delivered: false, hasMeasuredReading: false, lastPresentation: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(AirPodsNativeWarningReplayPolicy.shouldPresent(delivered: false, hasMeasuredReading: false, lastPresentation: now.addingTimeInterval(-301), now: now))
    }

    func testCompactLowBatteryLabelFitsOutsideCameraAtExistingWidth() throws {
        let descriptor = try XCTUnwrap(NSFont.systemFont(ofSize: 12, weight: .semibold).fontDescriptor.withDesign(.rounded))
        let font = try XCTUnwrap(NSFont(descriptor: descriptor, size: 12))
        let titleWidth = ("Low Battery" as NSString).size(withAttributes: [.font: font]).width
        // Rounded font metrics vary slightly by macOS release. The label may
        // scale within its wing, but must never need the camera lane.
        XCTAssertLessThanOrEqual(titleWidth * BatteryCompactWarningLayout.minimumLabelScale, BatteryCompactWarningLayout.contentWidth)
        for cameraWidth: CGFloat in [179, 185, 200] {
            let totalWidth = cameraWidth + BatteryCompactWarningLayout.extraWidth
            let cameraStart = (totalWidth - cameraWidth) / 2
            let labelEnd = BatteryCompactWarningLayout.outerPadding + BatteryCompactWarningLayout.contentWidth
            XCTAssertEqual(cameraStart - labelEnd, BatteryCompactWarningLayout.cameraClearance)
            XCTAssertEqual(2 * (BatteryCompactWarningLayout.wingWidth + BatteryCompactWarningLayout.outerPadding) + cameraWidth, totalWidth)
        }
    }

    func testCriticalGlowFillsEdgesFeathersInwardAndLeavesCenterTransparent() throws {
        let image = try XCTUnwrap(CriticalBatteryBorderLayout.makeGlowImage(scale: 1, cornerRadius: 18))
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[y * image.bytesPerRow + x * 4 + 3]) }
        XCTAssertGreaterThan(alpha(0, 80), 180) // Flush edge; no inset black gap.
        XCTAssertGreaterThan(alpha(20, 80), 120) // Actual broad glow, not a line/shadow.
        XCTAssertGreaterThan(alpha(40, 80), 40)
        XCTAssertLessThan(alpha(60, 80), 15)
        XCTAssertEqual(alpha(80, 80), 0)
        XCTAssertEqual(alpha(0, 0), 0) // Built-in display's rounded outer corner.
        XCTAssertGreaterThan(alpha(7, 7), 80)
        XCTAssertEqual(alpha(20, 80), alpha(80, 20))
    }

    func testCriticalGlowHandlesRetinaAndSquareExternalDisplays() throws {
        let image = try XCTUnwrap(CriticalBatteryBorderLayout.makeGlowImage(scale: 2, cornerRadius: 0))
        XCTAssertEqual(image.width, 320)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertGreaterThan(bytes[3], 180) // External display corner reaches its actual edge.
        XCTAssertEqual(bytes[160 * image.bytesPerRow + 160 * 4 + 3], 0)
    }

    func testPerWarningStyleOverridesOldLowBatteryStyleInSharedPresentation() {
        XCTAssertEqual(BatteryTemporaryHUDPresentation.style(for: .lowBattery, lowWarningOverride: .compact,
            lowDefault: .standard, fullDefault: .standard), .compact)
        XCTAssertEqual(BatteryTemporaryHUDPresentation.style(for: .lowBattery, lowWarningOverride: .standard,
            lowDefault: .compact, fullDefault: .compact), .standard)
        XCTAssertEqual(BatteryTemporaryHUDPresentation.style(for: .lowBattery, lowWarningOverride: nil,
            lowDefault: .standard, fullDefault: .compact), .standard)
        XCTAssertEqual(BatteryTemporaryHUDPresentation.style(for: .fullBattery, lowWarningOverride: .standard,
            lowDefault: .standard, fullDefault: .compact), .compact)
        XCTAssertEqual(BatteryTemporaryHUDPresentation.style(for: .charging, lowWarningOverride: .standard,
            lowDefault: .standard, fullDefault: .standard), .compact)
    }

    func testMacPowerEventStyleChoicesDoNotOverrideWarningPresentation() {
        for kind in [BatteryTemporaryHUDKind.charging, .unplugged, .lowPowerEnabled, .lowPowerDisabled] {
            for choice in BatteryNotificationStyle.allCases {
                XCTAssertEqual(BatteryTemporaryHUDPresentation.style(for: kind, lowWarningOverride: .standard,
                    lowDefault: .standard, fullDefault: .standard, powerStyle: choice), choice)
            }
        }
        XCTAssertEqual(BatteryTemporaryHUDPresentation.style(for: .lowBattery, lowWarningOverride: .compact,
            lowDefault: .standard, fullDefault: .standard, powerStyle: .standard), .compact)
        XCTAssertEqual(BatteryTemporaryHUDPresentation.style(for: .fullBattery, lowWarningOverride: nil,
            lowDefault: .standard, fullDefault: .standard, powerStyle: .compact), .standard)
    }

    func testLowBatteryWarningsFireOnceAtEachDescendingThreshold() {
        var tracker = LowBatteryWarningTracker()
        let warnings = LowBatteryWarning.defaults
        for level: Int in [15, 10, 5, 1] {
            XCTAssertEqual(tracker.update(previous: Float(level + 1), current: Float(level), connectedToPower: false, warnings: warnings)?.percentage, level)
            XCTAssertNil(tracker.update(previous: Float(level + 1), current: Float(level), connectedToPower: false, warnings: warnings))
        }
        XCTAssertEqual(tracker.delivered, [15, 10, 5, 1])
    }

    func testLowBatterySleepDropShowsOnlyMostUrgentCrossedLevel() {
        var tracker = LowBatteryWarningTracker()
        let warning = tracker.update(previous: 25, current: 0, connectedToPower: false, warnings: LowBatteryWarning.defaults)
        XCTAssertEqual(warning?.percentage, 1)
        XCTAssertEqual(warning?.presentation, .critical)
        XCTAssertEqual(tracker.delivered, [15, 10, 5, 1])
    }

    func testChargingRecoveryRearmsWithoutBoundarySpam() {
        var tracker = LowBatteryWarningTracker()
        let warnings = LowBatteryWarning.defaults
        XCTAssertEqual(tracker.update(previous: 16, current: 15, connectedToPower: false, warnings: warnings)?.percentage, 15)
        XCTAssertNil(tracker.update(previous: 15, current: 16, connectedToPower: true, warnings: warnings))
        XCTAssertNil(tracker.update(previous: 16, current: 15, connectedToPower: false, warnings: warnings))
        XCTAssertNil(tracker.update(previous: 15, current: 17, connectedToPower: true, warnings: warnings))
        XCTAssertEqual(tracker.update(previous: 17, current: 15, connectedToPower: false, warnings: warnings)?.percentage, 15)
    }

    func testWarningsIgnorePowerInvalidAndNonDescendingSamples() {
        var tracker = LowBatteryWarningTracker()
        let warnings = LowBatteryWarning.defaults
        XCTAssertNil(tracker.update(previous: 16, current: 15, connectedToPower: true, warnings: warnings))
        XCTAssertNil(tracker.update(previous: 15, current: 16, connectedToPower: false, warnings: warnings))
        XCTAssertNil(tracker.update(previous: 15, current: 15, connectedToPower: false, warnings: warnings))
        XCTAssertNil(tracker.update(previous: .nan, current: 1, connectedToPower: false, warnings: warnings))
        XCTAssertNil(tracker.update(previous: 100, current: -1, connectedToPower: false, warnings: warnings))
        XCTAssertTrue(tracker.delivered.isEmpty)
    }

    func testDisabledDuplicateAndMalformedWarningsAreSafe() {
        let warnings = [LowBatteryWarning(percentage: 15, enabled: false),
            LowBatteryWarning(percentage: 10, duration: 100),
            LowBatteryWarning(percentage: 10, duration: 0, presentation: .critical),
            LowBatteryWarning(percentage: -1), LowBatteryWarning(percentage: 101)]
        var tracker = LowBatteryWarningTracker()
        let warning = tracker.update(previous: 20, current: 9, connectedToPower: false, warnings: warnings)
        XCTAssertEqual(warning?.percentage, 10)
        XCTAssertEqual(warning?.presentation, .critical)
        XCTAssertEqual(warning?.duration, 1)
        XCTAssertEqual(tracker.delivered, [10])
        XCTAssertNil(tracker.update(previous: 20, current: 0, connectedToPower: false, warnings: []))
    }

    func testDeliveredWarningsSurviveRestartAndRecoveredBatteryResetsThem() {
        var tracker = LowBatteryWarningTracker(delivered: [15, 10])
        XCTAssertNil(tracker.update(previous: 11, current: 10, connectedToPower: false, warnings: LowBatteryWarning.defaults))
        tracker.resetRecoveredWarnings(at: 17)
        XCTAssertTrue(tracker.delivered.isEmpty)
        XCTAssertEqual(tracker.update(previous: 17, current: 15, connectedToPower: false, warnings: LowBatteryWarning.defaults)?.percentage, 15)
    }

    func testCustomWarningsAndLegacySettingsAreRetained() {
        let migrated = LowBatteryWarning.initialWarnings(legacyThreshold: 12, legacyDuration: 7, legacyStyle: .standard)
        XCTAssertEqual(migrated.map(\.percentage), [15, 12, 10, 5, 1])
        XCTAssertEqual(migrated.first(where: { $0.percentage == 12 })?.duration, 7)
        XCTAssertEqual(migrated.first(where: { $0.percentage == 12 })?.presentation, .expanded)
        XCTAssertEqual(LowBatteryWarning.initialWarnings(legacyThreshold: 20, legacyDuration: 3, legacyStyle: .standard).map(\.percentage), [15, 10, 5, 1])
        var tracker = LowBatteryWarningTracker()
        let custom = [LowBatteryWarning(percentage: 35, duration: 20, presentation: .expanded, sound: false)]
        XCTAssertEqual(tracker.update(previous: 36, current: 35, connectedToPower: false, warnings: custom), custom[0])
        XCTAssertEqual(LowBatteryWarning.nextPercentage(in: LowBatteryWarning.defaults), 20)
        XCTAssertNil(LowBatteryWarning.nextPercentage(in: (1...99).map { LowBatteryWarning(percentage: $0) }))
    }

    func testBatteryIconStatusColorsAndPriority() {
        XCTAssertEqual(BatteryIconState.resolve(level: 19, charging: false, lowPower: false), .lowCharge)
        XCTAssertEqual(BatteryIconState.resolve(level: 19, charging: true, lowPower: true), .lowCharge)
        XCTAssertEqual(BatteryIconState.resolve(level: 20, charging: false, lowPower: false), .battery)
        XCTAssertEqual(BatteryIconState.resolve(level: 20, charging: true, lowPower: true), .lowPower)
        XCTAssertEqual(BatteryIconState.resolve(level: 80, charging: true, lowPower: false), .charging)
        XCTAssertEqual(BatteryIconState.resolve(level: 80, charging: false, lowPower: false), .battery)
        XCTAssertEqual(BatteryIconState.resolve(level: .nan, charging: false, lowPower: false), .battery)
    }

    func testDesktopToastKeepsCompactCameraSafeWings() {
        let size = DesktopSwitchLayout.contentSize(closedSize: CGSize(width: 179, height: 32))
        XCTAssertEqual(size, CGSize(width: 227, height: 32))
        XCTAssertEqual(DesktopSwitchLayout.wingWidth(height: 32), 24)
        let taller = DesktopSwitchLayout.contentSize(closedSize: CGSize(width: 200, height: 44))
        XCTAssertEqual(taller, CGSize(width: 264, height: 44))
    }

    func testDesktopNumbersUseEachDisplaysCurrentSpaceAndOrder() {
        let snapshot = DesktopSpaceSnapshot.decode([
            ["Display Identifier": "A", "Current Space": ["id64": 42],
             "Spaces": [["id64": 8, "type": 0], ["id64": 42, "type": 0]]],
            ["Display Identifier": "B", "Current Space": ["ManagedSpaceID": 9],
             "Spaces": [["ManagedSpaceID": 9, "type": 0], ["id64": 7, "type": 0]]]
        ])
        XCTAssertEqual(snapshot.numbers, ["A": 2, "B": 1])
    }

    func testFullscreenSpacesAreNotNumberedAsDesktops() {
        let snapshot = DesktopSpaceSnapshot.decode([
            ["Display Identifier": "A", "Current Space": ["id64": 3],
             "Spaces": [["id64": 1, "type": 0], ["id64": 2, "type": 4], ["id64": 3, "type": 0]]],
            ["Display Identifier": "B", "Current Space": ["id64": 2],
             "Spaces": [["id64": 1, "type": 0], ["id64": 2, "type": 4]]]
        ])
        XCTAssertEqual(snapshot.numbers, ["A": 2, "B": 0])
        XCTAssertEqual(snapshot.changes(from: .init(numbers: ["A": 1, "B": 1])), ["A": 2])
        XCTAssertEqual(DesktopSpaceSnapshot(numbers: ["B": 1]).changes(from: .init(numbers: ["B": 0])), ["B": 1])
    }

    func testDesktopChangesIgnoreLaunchAndNewDisplays() {
        let snapshot = DesktopSpaceSnapshot(numbers: ["A": 2, "B": 1])
        XCTAssertTrue(snapshot.changes(from: .init(numbers: [:])).isEmpty)
        XCTAssertTrue(snapshot.changes(from: snapshot).isEmpty)
        XCTAssertEqual(snapshot.changes(from: .init(numbers: ["A": 1])), ["A": 2])
    }

    func testMalformedDesktopSnapshotsDoNotInventNumbers() {
        XCTAssertTrue(DesktopSpaceSnapshot.decode([
            ["Display Identifier": "A", "Spaces": [["id64": 1, "type": 0]]],
            ["Current Space": ["id64": 1], "Spaces": []],
            ["Display Identifier": "B", "Current Space": ["id64": 1], "Spaces": "invalid"]
        ]).numbers.isEmpty)
    }

    @MainActor
    func testDesktopToastDoesNotDisplaceHigherPriorityHUDs() {
        for type: SneakContentType in [.volume, .brightness, .capsLock, .bluetoothAudio, .privacy, .timer, .reminder] {
            XCTAssertFalse(DesktopSwitchManager.canPresent(over: sneakPeek(show: true, type: type)))
        }
        XCTAssertTrue(DesktopSwitchManager.canPresent(over: sneakPeek(show: true, type: .music)))
        XCTAssertTrue(DesktopSwitchManager.canPresent(over: sneakPeek(show: true, type: .desktop)))
        XCTAssertTrue(DesktopSwitchManager.canPresent(over: sneakPeek(show: false, type: .volume)))
    }

    @MainActor
    func testNormalNotchClipInterpolatesTheShapeItActuallyDraws() {
        let closed = NotchShape(topCornerRadius: 7, bottomCornerRadius: 16)
        let opened = NotchShape(topCornerRadius: 21, bottomCornerRadius: 27)
        let start = BreakReminderClipModifier(isActive: false, notchShape: closed, fallback: AnyShape(closed)).resolvedShape
        var end = BreakReminderClipModifier(isActive: false, notchShape: opened, fallback: AnyShape(opened)).resolvedShape
        var delta = end.animatableData - start.animatableData
        delta.scale(by: 0.25)
        end.animatableData = start.animatableData + delta
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        XCTAssertEqual(end.path(in: rect), NotchShape(topCornerRadius: 10.5, bottomCornerRadius: 18.75).path(in: rect))
        XCTAssertNotEqual(end.path(in: rect), opened.path(in: rect))
    }

    @MainActor
    func testBreakClipUsesItsOwnInterpolatedCorners() {
        let closed = NotchShape(topCornerRadius: 7, bottomCornerRadius: 16)
        let preview = NotchShape(topCornerRadius: 7, bottomCornerRadius: 32)
        let start = BreakReminderClipModifier(isActive: true, notchShape: closed, fallback: AnyShape(Circle())).resolvedShape
        var end = BreakReminderClipModifier(isActive: true, notchShape: preview, fallback: AnyShape(Circle())).resolvedShape
        var delta = end.animatableData - start.animatableData
        delta.scale(by: 0.5)
        end.animatableData = start.animatableData + delta
        let rect = CGRect(x: 0, y: 0, width: 380, height: 152)
        XCTAssertEqual(end.path(in: rect), NotchShape(topCornerRadius: 7, bottomCornerRadius: 24).path(in: rect))
    }

    @MainActor
    func testFallbackPillKeepsItsOwnAnimationData() {
        let start = BreakReminderClipModifier(isActive: false, notchShape: NotchShape(),
            fallback: AnyShape(DynamicIslandPillShape(cornerRadius: 16))).resolvedShape
        var end = BreakReminderClipModifier(isActive: false, notchShape: NotchShape(),
            fallback: AnyShape(DynamicIslandPillShape(cornerRadius: 32))).resolvedShape
        var delta = end.animatableData - start.animatableData
        delta.scale(by: 0.5)
        end.animatableData = start.animatableData + delta
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        XCTAssertEqual(end.path(in: rect), DynamicIslandPillShape(cornerRadius: 24).path(in: rect))
    }

    func testMusicWingHoverIsNotCancelledByPhysicalNotchPolling() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let fallback = CGSize(width: 179 + 24, height: 32)
        let wingPoint = CGPoint(x: screen.midX - 120, y: screen.maxY - 16)
        let oldFrame = ClosedSurfaceHoverGeometry.frame(screenFrame: screen, fallbackSize: fallback, renderedSize: .zero)
        XCTAssertFalse(ClosedSurfaceHoverGeometry.contains(wingPoint, in: oldFrame))
        let frame = ClosedSurfaceHoverGeometry.frame(screenFrame: screen, fallbackSize: fallback,
                                                    renderedSize: CGSize(width: 271, height: 32))
        XCTAssertTrue(ClosedSurfaceHoverGeometry.contains(wingPoint, in: frame))
        XCTAssertTrue(ClosedSurfaceHoverGeometry.contains(CGPoint(x: screen.midX + 120, y: wingPoint.y), in: frame))
        XCTAssertFalse(ClosedSurfaceHoverGeometry.contains(CGPoint(x: screen.midX + 160, y: wingPoint.y), in: frame))
    }

    func testTallPreviewHoverUsesItsVisibleBody() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let frame = ClosedSurfaceHoverGeometry.frame(screenFrame: screen, fallbackSize: CGSize(width: 203, height: 32),
                                                    renderedSize: CGSize(width: 380, height: 152))
        XCTAssertTrue(ClosedSurfaceHoverGeometry.contains(CGPoint(x: screen.midX, y: screen.maxY - 120), in: frame))
        XCTAssertFalse(ClosedSurfaceHoverGeometry.contains(CGPoint(x: screen.midX, y: screen.maxY - 170), in: frame))
    }

    func testIdleHoverKeepsExistingFallbackClearanceAndInclusiveTopEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let frame = ClosedSurfaceHoverGeometry.frame(screenFrame: screen, fallbackSize: CGSize(width: 203, height: 32),
                                                    renderedSize: CGSize(width: 179, height: 32))
        XCTAssertEqual(frame.size, CGSize(width: 203, height: 38))
        XCTAssertTrue(ClosedSurfaceHoverGeometry.contains(CGPoint(x: screen.midX, y: screen.maxY), in: frame))
        XCTAssertFalse(ClosedSurfaceHoverGeometry.contains(CGPoint(x: screen.midX - 120, y: screen.maxY - 16), in: frame))
    }

    func testShiftedExternalPillHoverFollowsVisiblePosition() {
        let screen = CGRect(x: 1470, y: -100, width: 1920, height: 1080)
        let frame = ClosedSurfaceHoverGeometry.frame(screenFrame: screen, fallbackSize: CGSize(width: 203, height: 32),
            renderedSize: CGSize(width: 271, height: 32), horizontalOffset: 90, topInset: 12)
        XCTAssertEqual(frame.midX, screen.midX + 90)
        XCTAssertEqual(frame.maxY, screen.maxY - 12)
        XCTAssertTrue(ClosedSurfaceHoverGeometry.contains(CGPoint(x: frame.midX - 120, y: frame.maxY - 16), in: frame))
    }

    func testBreakDeadlineCompletesAfterDelayedTickOrSleep() {
        let start = Date(timeIntervalSince1970: 1000)
        let deadline = start.addingTimeInterval(20)
        XCTAssertEqual(BreakReminderManager.remaining(until: deadline, now: start), 20)
        XCTAssertEqual(BreakReminderManager.remaining(until: deadline, now: deadline), 0)
        XCTAssertEqual(BreakReminderManager.remaining(until: deadline, now: start.addingTimeInterval(3600)), 0)
        XCTAssertEqual(BreakReminderManager.remaining(until: deadline, now: deadline.addingTimeInterval(-0.2)), 1)
    }
    func testBreakProgressUsesDeadlineAndClampsAfterSleep() {
        let start = Date(timeIntervalSince1970: 1000)
        let deadline = start.addingTimeInterval(20)
        XCTAssertEqual(BreakReminderManager.progress(until: deadline, duration: 20, now: start), 0)
        XCTAssertEqual(BreakReminderManager.progress(until: deadline, duration: 20, now: start.addingTimeInterval(10)), 0.5)
        XCTAssertEqual(BreakReminderManager.progress(until: deadline, duration: 20, now: start.addingTimeInterval(3600)), 1)
        XCTAssertEqual(BreakReminderManager.progress(until: deadline, duration: 20, now: start.addingTimeInterval(-10)), 0)
        XCTAssertEqual(BreakReminderManager.progress(until: deadline, duration: 0, now: start), 0)
    }
    func testRecordingCannotBlockBreakButTemporaryControlsCan() {
        XCTAssertFalse(BreakReminderManager.yieldsToHUD(show: true, type: .recording))
        XCTAssertTrue(BreakReminderManager.yieldsToHUD(show: true, type: .volume))
        XCTAssertTrue(BreakReminderManager.yieldsToHUD(show: true, type: .brightness))
        XCTAssertFalse(BreakReminderManager.yieldsToHUD(show: false, type: .brightness))
    }

    func testSnappingUsesVisibleFrameAndMultiScreenCoordinates() {
        let visible = CGRect(x: -1920, y: 40, width: 1920, height: 1040)
        let left = WindowSnapManager.target(.left, visibleFrame: visible, ratio: 0.6)
        let right = WindowSnapManager.target(.right, visibleFrame: visible, ratio: 0.6)
        XCTAssertEqual(left.width, 1152, accuracy: 0.001)
        XCTAssertEqual(left.maxX, right.minX, accuracy: 0.001)
        XCTAssertEqual(right.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertEqual(WindowSnapManager.accessibilityRect(left, primaryTop: 1117).minY, 37)
        XCTAssertEqual(WindowSnapManager.target(.maximize, visibleFrame: visible, ratio: 0.6), visible)
    }
    func testDragSnapSelectionOnlyAcceptsVisibleLayoutTiles() {
        let frame = CGRect(x: 100, y: 200, width: 360, height: 90)
        XCTAssertEqual(WindowSnapManager.selection(at: CGPoint(x: 130, y: 260), panelFrame: frame), .left)
        XCTAssertEqual(WindowSnapManager.selection(at: CGPoint(x: 220, y: 260), panelFrame: frame), .right)
        XCTAssertEqual(WindowSnapManager.selection(at: CGPoint(x: 300, y: 260), panelFrame: frame), .maximize)
        XCTAssertEqual(WindowSnapManager.selection(at: CGPoint(x: 400, y: 260), panelFrame: frame), .restore)
        XCTAssertNil(WindowSnapManager.selection(at: CGPoint(x: 193, y: 260), panelFrame: frame))
        XCTAssertNil(WindowSnapManager.selection(at: CGPoint(x: 130, y: 210), panelFrame: frame))
        XCTAssertNil(WindowSnapManager.selection(at: CGPoint(x: 480, y: 260), panelFrame: frame))
    }

    func testBatteryHistoryRetentionPrunesOldAndDuplicateSamples() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func sample(_ date: Date) -> BatteryHistorySample {
            BatteryHistorySample(date: date, level: 50, charging: false, pluggedIn: false, watts: nil, volts: nil, amps: nil, cycles: nil, health: nil)
        }
        let records = [sample(now), sample(now), sample(now.addingTimeInterval(-31 * 86400)), sample(now.addingTimeInterval(60)), sample(now.addingTimeInterval(-60))]
        let retained = BatteryHistoryManager.retained(records, now: now)
        XCTAssertEqual(retained.count, 2)
        XCTAssertEqual(retained.first?.date, now.addingTimeInterval(-60))
        XCTAssertEqual(retained.last?.date, now)
    }
    func testBatteryTimelineKeepsSixHourAxisDespiteSparseHistory() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let domain = BatteryHistoryManager.timeDomain(hours: 6, now: now)
        XCTAssertEqual(domain.upperBound.timeIntervalSince(domain.lowerBound), 21_600)
        func sample(_ offset: TimeInterval) -> BatteryHistorySample {
            BatteryHistorySample(date: now.addingTimeInterval(offset), level: 50, charging: false, pluggedIn: false, watts: nil, volts: nil, amps: nil, cycles: nil, health: nil)
        }
        let records = [sample(-21_601), sample(-21_600), sample(-120), sample(-60), sample(0), sample(1)]
        XCTAssertEqual(BatteryHistoryManager.samples(records, in: domain).count, 4)
        XCTAssertEqual(BatteryHistoryManager.samples([sample(-60)], in: domain).count, 1)
        XCTAssertEqual(BatteryHistoryManager.timeDomain(hours: 24, now: now).lowerBound, now.addingTimeInterval(-86_400))
    }
    func testReminderPopUpDoesNotFixOpenHeaderAtClosedWidth() {
        XCTAssertTrue(ClosedSneakPeekSizing.needsFixedSize(
            type: .reminder, style: .standard,
            isVisible: true, isClosed: true, hideOnClosed: false
        ))
        XCTAssertFalse(ClosedSneakPeekSizing.needsFixedSize(
            type: .reminder, style: .standard,
            isVisible: true, isClosed: false, hideOnClosed: false
        ))
        XCTAssertFalse(ClosedSneakPeekSizing.needsFixedSize(
            type: .timer, style: .standard,
            isVisible: true, isClosed: false, hideOnClosed: false
        ))
    }

    func testCompactCapsLockGlyphKeepsCameraClearance() {
        let inset = InlineHUD.capsLockGlyphInset(
            leadingWidth: 56, centerWidth: 190,
            trailingWidth: 0, physicalWidth: 179
        )
        let visibleLeftWing = (56 + 190 + 16 - 190) / 2
        XCTAssertEqual(inset, 12)
        XCTAssertLessThanOrEqual(inset + 20 + 4, CGFloat(visibleLeftWing))

        let widerCameraInset = InlineHUD.capsLockGlyphInset(
            leadingWidth: 56, centerWidth: 190,
            trailingWidth: 0, physicalWidth: 210
        )
        XCTAssertEqual(widerCameraInset, 2)
    }

    func testListeningModePreservesCompactAsymmetricWings() {
        XCTAssertEqual(
            InlineHUD.airPodsListeningModeWidth(closedNotchWidth: 183, gestureProgress: 0),
            183 - 20 + 44 + 180
        )
        XCTAssertEqual(
            InlineHUD.safeWingWidth(leadingWidth: 44, centerWidth: 159, trailingWidth: 180, physicalWidth: 179),
            102
        )
    }

    func testBluetoothNameIsLimitedToTheVisibleLeftWing() {
        let visible = InlineHUD.safeWingWidth(
            leadingWidth: 132, centerWidth: 159, trailingWidth: 112, physicalWidth: 179
        )
        XCTAssertEqual(visible, 112)
        XCTAssertEqual(visible - 25, 87)
    }

    func testRecordingHoverUsesMainOpeningWithoutIntermediateControlExpansion() {
        for sharing in [false, true] {
            for opensOnHover in [false, true] {
                let suppressed = suppressRecordingHoverExpansion(screenSharingAppActive: sharing, opensNotchOnHover: opensOnHover)
                for style in [RecordingHoverStyle.default, .inline] {
                    let layout = RecordingHUDLayout(isVisible: true, stopControlsEnabled: true,
                        hoverStyle: style, expanded: true, suppressHoverExpansion: suppressed)
                    XCTAssertEqual(layout.presentation, sharing || opensOnHover ? .compact : (style == .default ? .expanded : .inline))
                }
            }
        }
    }

    func testRecordingTransitionCanvasContainsClosedAndOpenSurfaces() {
        let opened = CGSize(width: 600, height: 230)
        for closed in [CGSize(width: 311, height: 32), CGSize(width: 355, height: 32),
                       CGSize(width: 319, height: 102), CGSize(width: 650, height: 300)] {
            let canvas = recordingTransitionCanvas(surface: closed, opened: opened)
            XCTAssertGreaterThanOrEqual(canvas.width, closed.width)
            XCTAssertGreaterThanOrEqual(canvas.height, closed.height)
            XCTAssertGreaterThanOrEqual(canvas.width, opened.width)
            XCTAssertGreaterThanOrEqual(canvas.height, opened.height)
            XCTAssertEqual(recordingTransitionCanvas(surface: opened, opened: canvas), canvas)
        }
    }

    func testRecordingWingsKeepCameraClearanceCentered() {
        for presentation in [RecordingHUDPresentation.compact, .inline] {
            let closedWidth: CGFloat = 179
            let surfaceWidth = closedWidth + presentation.extraWidth
            let centerStart = (surfaceWidth - closedWidth) / 2

            XCTAssertEqual(presentation.wingWidth * 2 + closedWidth, surfaceWidth)
            XCTAssertEqual(presentation.wingWidth, centerStart)
            XCTAssertGreaterThanOrEqual(presentation.wingWidth, 66)
        }
    }

    func testForegroundHUDTakesSizingPriorityOverRecording() {
        let recording = RecordingHUDLayout(
            isVisible: true,
            stopControlsEnabled: false,
            hoverStyle: .default,
            expanded: false,
            suppressHoverExpansion: false
        )
        let closedSize = CGSize(width: 179, height: 32)

        XCTAssertEqual(
            recording.sizeWhenFrontmost(
                closedNotchSize: closedSize,
                effectiveClosedNotchHeight: 32,
                sneakPeekVisible: false,
                competingExpansionVisible: false
            )?.width,
            311
        )
        XCTAssertNil(recording.sizeWhenFrontmost(
            closedNotchSize: closedSize,
            effectiveClosedNotchHeight: 32,
            sneakPeekVisible: true,
            competingExpansionVisible: false
        ))
        XCTAssertNil(recording.sizeWhenFrontmost(
            closedNotchSize: closedSize,
            effectiveClosedNotchHeight: 32,
            sneakPeekVisible: false,
            competingExpansionVisible: true
        ))
    }

    func testPausedTrackDoesNotDisplaceActiveRecordingIndicator() {
        XCTAssertFalse(hasActiveClosedMusicSnapshot(
            isPlaying: false,
            isPlayerIdle: false,
            hasMusicMetadata: true,
            recordingIndicatorVisible: true
        ))
        XCTAssertTrue(hasActiveClosedMusicSnapshot(
            isPlaying: true,
            isPlayerIdle: false,
            hasMusicMetadata: true,
            recordingIndicatorVisible: true
        ))
    }

    func testPausedTrackKeepsPreviousMusicBehaviorWithoutRecording() {
        XCTAssertTrue(hasActiveClosedMusicSnapshot(
            isPlaying: false,
            isPlayerIdle: false,
            hasMusicMetadata: true,
            recordingIndicatorVisible: false
        ))
    }

    private let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    private let gap: CGFloat = 8

    private func offset(contentWidth: CGFloat, menusEnd: CGFloat, screen: CGRect? = nil) -> CGFloat {
        MenuBarLayout.clearanceOffset(
            contentWidth: contentWidth,
            screenFrame: screen ?? self.screen,
            menusRightEdge: menusEnd,
            gap: gap
        )
    }

    func testShortMenusLeaveTheNotchCentred() {
        // 300pt of content is centred at 855, so it begins at 705. Menus that
        // end at 606 -- Zen's, measured -- are nowhere near it.
        XCTAssertEqual(offset(contentWidth: 300, menusEnd: 606), 0)
    }

    func testMenusReachingTheContentPushItRight() {
        // Content begins at 705; menus ending at 720 overlap it by 15, plus the
        // 8pt gap.
        XCTAssertEqual(offset(contentWidth: 300, menusEnd: 720), 23)
    }

    func testTheGapAloneIsEnoughToMove() {
        // Menus end exactly where the content begins: no overlap, but they would
        // be flush, so the content still steps aside by the gap.
        XCTAssertEqual(offset(contentWidth: 300, menusEnd: 705), 8)
    }

    func testMenusEndingJustShortOfTheGapDoNotMove() {
        XCTAssertEqual(offset(contentWidth: 300, menusEnd: 697), 0)
    }

    func testAWiderActivityIsCoveredSooner() {
        // 500pt of content begins at 605, so the same menus that cleared a
        // 300pt activity now overlap it.
        XCTAssertEqual(offset(contentWidth: 500, menusEnd: 606), 9)
        XCTAssertEqual(offset(contentWidth: 300, menusEnd: 606), 0)
    }

    func testTheShiftStopsAtTheScreenEdge() {
        // Content this wide has only 105pt of room on the right, so a demand for
        // more than that is capped rather than pushing it off screen.
        let wide: CGFloat = 1500
        let headroom = screen.maxX - (screen.midX - wide / 2 + wide)
        XCTAssertEqual(offset(contentWidth: wide, menusEnd: 1000), headroom)
        XCTAssertEqual(headroom, 105)
    }

    func testContentFillingTheScreenNeverMoves() {
        XCTAssertEqual(offset(contentWidth: 1710, menusEnd: 900), 0)
    }

    func testNoContentMeansNoShift() {
        XCTAssertEqual(offset(contentWidth: 0, menusEnd: 900), 0)
    }

    func testAnExternalDisplayIsMeasuredOnItsOwnGeometry() {
        // A screen that does not start at x=0 -- the arithmetic is in global
        // coordinates, so a second display must not be treated as if it did.
        let external = CGRect(x: 1710, y: 0, width: 2560, height: 1440)
        // Centre is 2990, so 300pt of content begins at 2840.
        XCTAssertEqual(offset(contentWidth: 300, menusEnd: 2850, screen: external), 18)
        XCTAssertEqual(offset(contentWidth: 300, menusEnd: 2000, screen: external), 0)
    }

    func testExpandedHeaderUsesExactlyThePhysicalNotchWidth() {
        XCTAssertEqual(
            NotchHeaderLayout.deadSpaceWidth(
                configuredWidth: 160,
                physicalWidth: 185,
                hasPhysicalNotch: true
            ),
            185
        )
    }

    func testConfiguredNotchCanBeWiderThanThePhysicalNotch() {
        XCTAssertEqual(
            NotchHeaderLayout.deadSpaceWidth(
                configuredWidth: 240,
                physicalWidth: 185,
                hasPhysicalNotch: true
            ),
            240
        )
    }

    func testExternalDisplayUsesOnlyTheConfiguredClearance() {
        XCTAssertEqual(
            NotchHeaderLayout.deadSpaceWidth(
                configuredWidth: 160,
                physicalWidth: nil,
                hasPhysicalNotch: false
            ),
            160
        )
    }

    func testPhysicalNotchCannotBeCustomizedNarrowerThanHardware() {
        XCTAssertEqual(
            PhysicalNotchLayout.safeWidth(configuredWidth: 140, measuredWidth: 185),
            185
        )
    }

    func testPhysicalNotchCustomizationCanStillWidenClearance() {
        XCTAssertEqual(
            PhysicalNotchLayout.safeWidth(configuredWidth: 230, measuredWidth: 185),
            230
        )
    }
}
