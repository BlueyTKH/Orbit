import SwiftUI
import WidgetKit
import AppIntents

struct OrbitDeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Battery device"
    static let defaultQuery = OrbitDeviceQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct OrbitDeviceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [OrbitDeviceEntity] {
        let devices = OrbitBatteryStore.read()?.devices ?? []
        return identifiers.compactMap { id in devices.first { $0.id == id || ($0.aliases ?? []).contains(id) }.map { OrbitDeviceEntity(id: id, name: $0.name) } }
    }
    func suggestedEntities() async throws -> [OrbitDeviceEntity] {
        (OrbitBatteryStore.read()?.devices ?? []).map { OrbitDeviceEntity(id: $0.id, name: $0.name) }
    }
}
enum OrbitWidgetStyle: String, AppEnum {
    case rings, list, bars
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.rings: "Rings", .list: "List", .bars: "Bars"]
}
struct OrbitBatteryConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Orbit Batteries"
    static let description = IntentDescription("Choose devices in your preferred order, or leave empty for Automatic: lowest battery first.")
    @Parameter(title: "Style", default: .rings) var style: OrbitWidgetStyle
    @Parameter(title: "Devices (empty = Automatic)") var devices: [OrbitDeviceEntity]?
    @Parameter(title: "Monochrome", default: false) var monochrome: Bool
    @Parameter(title: "List progress bars", default: true) var progressBars: Bool
}
struct OrbitBatteryEntry: TimelineEntry {
    let date: Date
    let configuration: OrbitBatteryConfiguration
    let snapshot: OrbitBatterySnapshot?
}
struct OrbitBatteryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> OrbitBatteryEntry {
        .init(date: Date(), configuration: .init(), snapshot: nil)
    }
    func snapshot(for configuration: OrbitBatteryConfiguration, in context: Context) async -> OrbitBatteryEntry {
        .init(date: Date(), configuration: configuration, snapshot: OrbitBatteryStore.read())
    }
    func timeline(for configuration: OrbitBatteryConfiguration, in context: Context) async -> Timeline<OrbitBatteryEntry> {
        let now = Date()
        return Timeline(entries: [.init(date: now, configuration: configuration, snapshot: OrbitBatteryStore.read())], policy: .after(now.addingTimeInterval(60)))
    }
}
struct OrbitBatteryWidgetView: View {
    let entry: OrbitBatteryEntry
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { familyOverride ?? systemFamily }
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var limit: Int { family == .systemSmall ? 1 : family == .systemMedium ? 4 : family == .systemLarge ? 8 : 12 }
    private var devices: [OrbitBatteryDevice] {
        Array((entry.snapshot?.selected(ids: entry.configuration.devices?.map(\.id) ?? [], at: entry.date) ?? []).prefix(limit))
    }
    private func colour(_ device: OrbitBatteryDevice) -> Color {
        guard !entry.configuration.monochrome, renderingMode == .fullColor,
              let level = device.usableLevel(at: entry.date) else { return .primary }
        return device.charging ? .green : level < 20 ? .red : level <= 30 ? .orange : .green
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.secondary)
                Text("Orbit").fontWeight(.semibold)
                Spacer(minLength: 2)
                if family != .systemSmall { Text(entry.configuration.devices?.isEmpty != false ? "Lowest first" : "Your devices").foregroundStyle(.secondary) }
            }.font(.caption2)
            if devices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "battery.100percent").font(.title2)
                    Text("Open Orbit").font(.headline)
                    Text("Connected batteries appear here.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if entry.configuration.style == .rings {
                let columns = family == .systemSmall ? 1 : family == .systemMedium ? 4 : family == .systemLarge ? 3 : 4
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 14) {
                    ForEach(devices) { device in ring(device) }
                }.frame(maxHeight: .infinity, alignment: .center)
            } else {
                VStack(spacing: family == .systemSmall ? 8 : 10) {
                    ForEach(devices) { device in row(device) }
                }.frame(maxHeight: .infinity, alignment: .top)
            }
            if let snapshot = entry.snapshot {
                HStack(spacing: 3) {
                    Text(entry.date.timeIntervalSince(snapshot.writtenAt) > 180 ? "Last update" : "Updated")
                    Text(snapshot.writtenAt, style: .relative)
                }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "orbit://batteries"))
    }
    private func ring(_ device: OrbitBatteryDevice) -> some View {
        let level = device.usableLevel(at: entry.date)
        return VStack(spacing: 5) {
            ZStack {
                Circle().stroke(.primary.opacity(0.1), lineWidth: 5)
                Circle().trim(from: 0, to: Double(level ?? 0) / 100).stroke(colour(device), style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: device.charging ? "bolt.fill" : device.symbol).font(.system(size: family == .systemSmall ? 23 : 17)).foregroundStyle(colour(device))
            }.frame(width: family == .systemSmall ? 58 : 42, height: family == .systemSmall ? 58 : 42)
            Text(level.map { "\($0)%" } ?? (device.connected ? "Stale" : "Offline")).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(device.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
    private func row(_ device: OrbitBatteryDevice) -> some View {
        let level = device.usableLevel(at: entry.date)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: device.symbol).frame(width: 20).foregroundStyle(colour(device))
                Text(device.name).lineLimit(1)
                Spacer(minLength: 2)
                if device.charging { Image(systemName: "bolt.fill").foregroundStyle(colour(device)) }
                Text(level.map { "\($0)%" } ?? "—").monospacedDigit()
            }.font(.system(size: 11, weight: .medium))
            if entry.configuration.style == .bars || entry.configuration.progressBars {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.09))
                        Capsule().fill(colour(device)).frame(width: geo.size.width * Double(level ?? 0) / 100)
                    }
                }.frame(height: entry.configuration.style == .bars ? 7 : 3)
            }
            if level == nil { Text(device.connected ? "Reading out of date" : "Offline").font(.system(size: 9)).foregroundStyle(.secondary) }
        }
    }
}
@main struct OrbitBatteryWidgets: Widget {
    let kind = OrbitBatteryStore.widgetKind
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: OrbitBatteryConfiguration.self, provider: OrbitBatteryProvider()) { entry in
            OrbitBatteryWidgetView(entry: entry)
        }
        .configurationDisplayName("Orbit Batteries")
        .description("Mac, trusted iPhone/iPad and connected accessories. Pick devices or keep the lowest battery in view.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
