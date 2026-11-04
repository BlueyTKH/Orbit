import AppKit
import SwiftUI
import Charts

/// Vector-drawn status item, with inverted text over the filled portion.
enum BatteryMenuIcon {
    static func tint(level: Int?, charging: Bool, lowPower: Bool) -> NSColor {
        if charging { return .systemGreen }
        if lowPower { return .systemYellow }
        if let level, level < 20 { return .systemRed }
        if let level, level <= 30 { return .systemOrange }
        return .systemGreen
    }
    static func image(level: Int?, charging: Bool, lowPower: Bool, color: Bool, percentage: Bool) -> NSImage {
        let width: CGFloat = percentage ? (charging ? 34 : 30) : 21
        let image = NSImage(size: NSSize(width: width + 4, height: 17), flipped: false) { _ in
            let body = NSRect(x: 0.5, y: 1.5, width: width, height: 14)
            let path = NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4)
            let accent = color ? tint(level: level, charging: charging, lowPower: lowPower) : .labelColor
            accent.withAlphaComponent(0.22).setFill(); path.fill()
            accent.withAlphaComponent(0.7).setStroke(); path.lineWidth = 0.8; path.stroke()
            accent.setFill()
            let fill = NSRect(x: body.minX, y: body.minY, width: body.width * CGFloat(min(100, max(0, level ?? 0))) / 100, height: body.height)
            NSGraphicsContext.saveGraphicsState(); path.addClip(); NSBezierPath(rect: fill).fill(); NSGraphicsContext.restoreGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: width + 1.5, y: 5.5, width: 2, height: 6), xRadius: 1, yRadius: 1).fill()
            let text = level.map(String.init) ?? "—"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let boltWidth: CGFloat = charging ? 6 : 0
            let gap: CGFloat = charging && percentage ? 2 : 0
            let groupWidth = (percentage ? textSize.width : 0) + gap + boltWidth
            let left = body.midX - groupWidth / 2
            func drawContents(_ ink: NSColor) {
                if percentage {
                    (text as NSString).draw(at: NSPoint(x: left, y: body.midY - textSize.height / 2 + 0.5),
                        withAttributes: [.font: font, .foregroundColor: ink])
                }
                if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [ink])) {
                    let x = left + (percentage ? textSize.width + gap : 0)
                    bolt.draw(in: NSRect(x: x, y: body.midY - 5, width: boltWidth, height: 10))
                }
            }
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            drawContents(.labelColor)
            NSBezierPath(rect: fill).addClip()
            drawContents(color ? .black : .controlBackgroundColor)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = (level.map { "Battery \($0) percent" } ?? "Battery unavailable")
            + (charging ? ", charging" : lowPower ? ", Low Power Mode" : "")
        return image
    }
}

#if !BATTERY_MENU_RENDER_CHECK
struct BatteryMenuContent: View {
    @ObservedObject var model: BatteryMenuModel
    @ObservedObject private var lowPower = LowPowerModeController.shared
    @State private var historyOpen = false
    var body: some View {
        BatteryMenuDashboard(snapshot: model.snapshot, applyingLowPower: lowPower.isApplying,
            errorMessage: lowPower.errorMessage,
            onLowPower: { lowPower.setEnabled(!model.snapshot.lowPower) },
            onHistory: { historyOpen = true },
            onSettings: { SettingsWindowController.shared.showWindow() },
            onSystemBattery: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") { NSWorkspace.shared.open(url) }
            },
            onActivity: { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) })
            .popover(isPresented: $historyOpen) { BatteryHistoryPopover() }
    }
}
#endif

struct BatteryMenuDashboard: View {
    let snapshot: BatteryMenuSnapshot
    var applyingLowPower = false
    var errorMessage: String? = nil
    var onLowPower: () -> Void = {}
    var onHistory: () -> Void = {}
    var onSettings: () -> Void = {}
    var onSystemBattery: () -> Void = {}
    var onActivity: () -> Void = {}
    var initialPage: String? = nil
    @State private var page = "Overview"
    private var selectedPage: String { initialPage ?? page }
    private var batterySymbol: String {
        if snapshot.charging { return "battery.100percent.bolt" }
        switch snapshot.level ?? 0 {
        case ...10: return "battery.0percent"
        case ...35: return "battery.25percent"
        case ...60: return "battery.50percent"
        case ...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    private var accent: Color { Color(nsColor: BatteryMenuIcon.tint(level: snapshot.level, charging: snapshot.charging, lowPower: snapshot.lowPower)) }
    private var batteryColour: Color { (snapshot.batteryWatts ?? 0) < -0.5 ? .orange : .mint }

    var body: some View {
        Group {
            #if BATTERY_MENU_RENDER_CHECK
            dashboardBody
            #else
            ScrollView { dashboardBody }
            #endif
        }
        .frame(width: 396)
        .background(LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.15), Color(red: 0.055, green: 0.065, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }
    private var dashboardBody: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Orbit", systemImage: "bolt.heart.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Orbit Settings")
                }
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(snapshot.level.map(String.init) ?? "—")
                                .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                            Text("%").font(.system(size: 22, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        }
                        Text(snapshot.level == nil ? "Battery unavailable" : snapshot.state)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                        Text(snapshot.eta ?? (snapshot.pluggedIn ? "Running on external power" : "Time estimate updating"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: batterySymbol)
                        .symbolRenderingMode(.palette).foregroundStyle(accent, accent.opacity(0.18))
                        .font(.system(size: 52, weight: .regular))
                }
                HStack(spacing: 4) {
                    ForEach(["Overview", "Devices", "Energy"], id: \.self) { tab in
                        Button { page = tab } label: {
                            Text(tab).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(selectedPage == tab ? .white : .secondary)
                                .frame(maxWidth: .infinity).frame(height: 28)
                                .background(selectedPage == tab ? Color.white.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(tab) battery section")
                    }
                }.padding(3).background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 11))
                if selectedPage == "Overview" {
                powerCard
                HStack {
                    sectionLabel("BATTERY HEALTH")
                    Spacer()
                    if let condition = snapshot.condition { Text(condition).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                }
                HStack(spacing: 8) {
                    metric(snapshot.health.map { "\($0)%" } ?? "—", "Max capacity", icon: "heart.fill", color: .mint)
                    metric(snapshot.cycles.map(String.init) ?? "—", "Cycles", icon: "arrow.trianglehead.2.clockwise.rotate.90", color: .cyan)
                    metric(snapshot.volts.map { String(format: "%.2f V", $0) } ?? "—", "Battery voltage", icon: "bolt.fill", color: .orange)
                }
                if let health = snapshot.health, health < 80 {
                    Label("Battery capacity is reduced. Check service options in Battery Settings.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                historyCard
                DisclosureGroup("Battery details") {
                    VStack(spacing: 8) {
                        detailRow("Current", snapshot.amps.map { String(format: "%+.2f A", $0) } ?? "Unavailable")
                        detailRow("Full charge capacity", snapshot.capacity.map { "\($0) mAh" } ?? "Unavailable")
                        detailRow("Design capacity", snapshot.designCapacity.map { "\($0) mAh" } ?? "Unavailable")
                    }.padding(.top, 8)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                } else if selectedPage == "Devices" {
                    if snapshot.devices.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "airpods").font(.system(size: 34)).foregroundStyle(.mint)
                            Text("Your connected devices appear here.").font(.system(size: 13, weight: .medium))
                            Text("AirPods show each earbud separately. Bluetooth audio, mouse and phone readings appear when available.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else { deviceCard }
                } else {
                    powerCard
                    energyCard
                }
                Divider().overlay(.white.opacity(0.08))
                Button(action: onLowPower) {
                    HStack {
                        Label("Low Power Mode", systemImage: "leaf.fill").foregroundStyle(snapshot.lowPower ? .yellow : .secondary)
                        Spacer()
                        if applyingLowPower { ProgressView().controlSize(.mini) }
                        else { Text(snapshot.lowPower ? "On" : "Off").foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 12, weight: .medium)).padding(12)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(applyingLowPower)
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.orange) }
                Button(action: onSystemBattery) { HStack { Text("Battery Settings"); Spacer(); Image(systemName: "arrow.up.right") } }
                    .font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain).padding(.horizontal, 4)
            }.padding(20)
    }
    private var powerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("POWER FLOW")
                Spacer()
                Text(snapshot.pluggedIn ? "External power" : "Battery power")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                VStack(spacing: 7) {
                    Image(systemName: snapshot.pluggedIn ? "powerplug.fill" : "battery.100percent")
                        .font(.system(size: 23)).foregroundStyle(.cyan)
                    Text(BatteryMenuSnapshot.watts(snapshot.pluggedIn ? snapshot.inputWatts : snapshot.batteryWatts))
                        .font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                    Text(snapshot.pluggedIn ? "Charger input" : "Battery output")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(width: 112)
                VStack(spacing: 28) {
                    Image(systemName: "arrow.right").foregroundStyle(.cyan.opacity(0.7))
                    if snapshot.pluggedIn {
                        Image(systemName: (snapshot.batteryWatts ?? 0) < -0.5 ? "arrow.left" : "arrow.right")
                            .foregroundStyle(batteryColour.opacity(0.7))
                    }
                }.font(.system(size: 12, weight: .medium)).frame(width: 18)
                VStack(spacing: 8) {
                    flowRow("Mac", icon: "laptopcomputer", watts: snapshot.systemWatts, color: .cyan)
                    if snapshot.pluggedIn {
                        flowRow("Battery", icon: "battery.100percent", watts: snapshot.batteryWatts, color: batteryColour)
                    } else {
                        Text("Powering your Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Circle().fill(batteryColour).frame(width: 5, height: 5)
                Text(snapshot.batteryFlow).font(.system(size: 11, weight: .medium))
                Spacer()
            }
            if snapshot.pluggedIn, let rating = snapshot.adapterRating {
                Text("\(rating) W adapter capacity · actual input is shown above")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("macOS telemetry can refresh slowly. Mac draw is input minus net battery charging; unavailable readings stay blank.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .animation(.easeInOut(duration: 0.35), value: snapshot.inputWatts)
            .animation(.easeInOut(duration: 0.35), value: snapshot.batteryWatts)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07), lineWidth: 1))
    }
    private func flowRow(_ title: String, icon: String, watts: Double?, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(BatteryMenuSnapshot.watts(watts)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 48)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { sectionLabel("LAST 24 HOURS"); Spacer(); Button("History", action: onHistory).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.mint) }
            if snapshot.history.count > 1 {
                Chart(snapshot.history) { point in
                    AreaMark(x: .value("Time", point.date), yStart: .value("Empty", 0), yEnd: .value("Charge", point.level))
                        .foregroundStyle(LinearGradient(colors: [.mint.opacity(0.25), .mint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.date), y: .value("Charge", point.level))
                        .foregroundStyle(.mint).lineStyle(StrokeStyle(lineWidth: 1.5))
                }.chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 52)
                HStack { Text("24 hours ago"); Spacer(); Text("Now") }.font(.system(size: 9)).foregroundStyle(.tertiary)
            } else { Text("History appears as Orbit records your battery.").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("YOUR DEVICES")
            ForEach(snapshot.devices) { device in
                HStack(spacing: 10) {
                    Image(systemName: device.symbol).font(.system(size: 19)).foregroundStyle(.mint).frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(device.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if let level = device.level {
                        Text("\(level)%").font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(level < 20 ? .red : .mint)
                    }
                }
            }
        }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
    private var energyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { sectionLabel("APP CPU POWER"); Spacer(); Button(action: onActivity) { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("Open Activity Monitor") }
            if snapshot.appEnergy.isEmpty {
                Text("Collecting supported app energy readings…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(snapshot.appEnergy) { app in
                HStack { Text(app.name).lineLimit(1); Spacer(); Text(BatteryMenuSnapshot.watts(app.watts)).monospacedDigit() }
                    .font(.system(size: 11))
            }
            Text("Partial CPU attribution for each app’s main process. Display, GPU, helper processes and background work are not included.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func metric(_ value: String, _ label: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 11))
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospacedDigit() }
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
    }
}
