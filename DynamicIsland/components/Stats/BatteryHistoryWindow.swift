import AppKit
import SwiftUI
import Charts

/// Frame ownership stays in AppKit, as in the notch's crash-protection fix.
@MainActor
final class NotchFlowUtilityWindow {
    let window: NSWindow
    init<Content: View>(title: String, size: CGSize, resizable: Bool = true, content: Content) {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.insert(.resizable); style.insert(.miniaturizable) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = size
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        ScreenCaptureVisibilityManager.shared.register(window, scope: .panelsOnly)
    }
    func show() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Uses the same transient, card-anchored presentation as the other Stats details.
struct BatteryHistoryPopover: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewerToken = UUID()

    var body: some View {
        BatteryHistoryDashboard()
            .frame(width: 560, height: 600)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close battery details")
            }
            .onAppear {
                BatteryHistoryManager.shared.setVisible(true, token: viewerToken)
            }
            .onDisappear {
                BatteryHistoryManager.shared.setVisible(false, token: viewerToken)
            }
    }
}

struct BatteryHistoryDashboard: View {
    @ObservedObject private var battery = BatteryHistoryManager.shared
    @State private var hours = 6
    private var timeDomain: ClosedRange<Date> {
        BatteryHistoryManager.timeDomain(hours: hours, now: Date())
    }
    private var records: [BatteryHistorySample] {
        let recent = BatteryHistoryManager.samples(battery.samples, in: timeDomain)
        let step = max(1, recent.count / 480)
        return recent.enumerated().filter { $0.offset.isMultiple(of: step) || $0.offset == recent.count - 1 }.map(\.element)
    }
    private func metric(_ name: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(name, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
    private func number(_ value: Double?, suffix: String) -> String {
        value.map { String(format: "%.2f %@", $0, suffix) } ?? "Unavailable"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Battery overview").font(.title2.weight(.bold))
                        Text(!BatteryHistoryManager.batterySupported ? "This Mac has no built-in battery" : battery.status?.isCharging == true ? "Charging" : battery.status?.isPluggedIn == true ? "Connected to power" : "Running on battery")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(battery.status?.percentage.map { "\($0)%" } ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.green).padding(.trailing, 22)
                }
                HStack(spacing: 10) {
                    metric(battery.health?.maximumCapacityPercent == nil ? "Estimated health" : "Health", (battery.health?.maximumCapacityPercent ?? battery.diagnostics.calculatedHealthPercent).map { "\($0)%" } ?? "Unavailable", "heart.fill", .pink)
                    metric("Condition", battery.health?.condition ?? "Unavailable", "checkmark.shield", .mint)
                    metric("Cycles", battery.diagnostics.cycleCount.map(String.init) ?? "Unavailable", "arrow.triangle.2.circlepath", .purple)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Charge history").font(.headline)
                    Picker("History range", selection: $hours) {
                        Text("6 hours").tag(6); Text("24 hours").tag(24); Text("7 days").tag(168); Text("30 days").tag(720)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if records.count < 2 {
                    ContentUnavailableView(BatteryHistoryManager.batterySupported ? "History is starting" : "No built-in battery", systemImage: "chart.xyaxis.line", description: Text(BatteryHistoryManager.batterySupported ? "A sample is saved each minute while your Mac is awake. The graph will grow as you use it." : "Battery history is available on Macs with an internal battery."))
                        .frame(height: 170)
                } else {
                    Chart(records) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("Charge", sample.level))
                            .foregroundStyle(.green).interpolationMethod(.linear)
                        if sample.charging {
                            PointMark(x: .value("Time", sample.date), y: .value("Charge", sample.level))
                                .foregroundStyle(.mint).symbolSize(10)
                        }
                    }.chartXScale(domain: timeDomain).chartYScale(domain: 0...100).chartYAxisLabel("Charge (%)").frame(height: 170)
                    Text("Mint dots mark charging. Sleep periods have no readings.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Battery power").font(.headline)
                Chart(records) { sample in
                    if let watts = sample.watts {
                        LineMark(x: .value("Time", sample.date), y: .value("Battery power", watts))
                            .foregroundStyle(.orange).interpolationMethod(.linear)
                    }
                }.chartXScale(domain: timeDomain).chartYAxisLabel("Watts").frame(height: 110)
                Text("Positive power enters the battery; negative power leaves it. This is battery power, not total system consumption.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    metric("Voltage", number(battery.diagnostics.voltageVolts, suffix: "V"), "bolt", .blue)
                    metric("Current", number(battery.diagnostics.currentAmps, suffix: "A"), "waveform.path", .orange)
                    metric("Adapter", battery.diagnostics.adapterWatts.map { "\($0) W" } ?? "Not connected", "powerplug", .cyan)
                }
                HStack(spacing: 10) {
                    metric("Full capacity", battery.diagnostics.fullChargeCapacityMAh.map { "\($0) mAh" } ?? "Unavailable", "battery.100percent", .green)
                    metric("Design capacity", battery.diagnostics.designCapacityMAh.map { "\($0) mAh" } ?? "Unavailable", "battery.100percent", .secondary)
                    metric("Temperature", "Unavailable", "thermometer.medium", .orange)
                }
                Text("Temperature needs a supported sensor reader. History stays on this Mac and is retained for 30 days; older readings are removed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = battery.storageError { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
