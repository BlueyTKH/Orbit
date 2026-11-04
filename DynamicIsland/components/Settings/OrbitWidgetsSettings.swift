import SwiftUI
import Defaults

struct OrbitWidgetsSettings: View {
    @ObservedObject private var nearby = NearbyBatteryManager.shared
    @Default(.orbitNearbyBatteriesEnabled) private var nearbyEnabled
    @ObservedObject private var hub = OrbitBatteryHub.shared
    @Default(.orbitTrustedDevicesEnabled) private var trustedDevices
    @Default(.orbitCombineDuplicateDevices) private var combineDuplicates
    @State private var previewStyle = "Rings"
    var body: some View {
        Form {
            Section("Every battery, one place") {
                Picker("Preview style", selection: $previewStyle) {
                    ForEach(["Rings", "List", "Bars"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                preview.padding(16).frame(maxWidth: .infinity, minHeight: 130)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                Text("Small, medium, large and extra-large widgets. Each widget has its own style, colour and device selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add an Orbit widget") {
                Label("Right-click the desktop and choose Edit Widgets, or open Notification Center → Edit Widgets.", systemImage: "1.circle.fill")
                Label("Search Orbit Batteries and choose a size.", systemImage: "2.circle.fill")
                Label("Right-click the widget → Edit Widget. Choose rings, list or bars, and select devices in your preferred order.", systemImage: "3.circle.fill")
                Text("Leave Devices empty for Automatic: the lowest available battery appears first. Widget updates are scheduled by macOS; the menu bar refreshes more often.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Nearby Bluetooth batteries") {
                Toggle("Discover nearby battery devices", isOn: $nearbyEnabled)
                Text("No cable required for devices exposing the Bluetooth Battery Service. Choose which devices to track below. iPhone/iPad availability depends on Bluetooth pairing and what the device exposes; proximity alone does not guarantee a reading.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(nearby.status).font(.caption).foregroundStyle(.secondary)
                if nearbyEnabled {
                    Button("Scan now") { nearby.scan() }
                    ForEach(nearby.candidates) { candidate in
                        HStack {
                            Text(candidate.name); Spacer()
                            Button(nearby.tracks(candidate.id) ? "Stop tracking" : "Track battery") {
                                nearby.track(candidate.id, enabled: !nearby.tracks(candidate.id))
                            }
                        }
                    }
                }
            }
            Section("Optional USB / Wi-Fi reader") {
                Toggle("Read already-trusted iPhone and iPad batteries", isOn: $trustedDevices)
                Text("Connect by cable, unlock the device and approve Trust in Finder/on the device. To connect later over Wi-Fi, enable Show this device when on Wi-Fi in Finder. Orbit never pairs a device or changes its settings for you.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("This optional reader connects only to already-trusted devices made reachable by macOS. Nearby Bluetooth discovery is configured separately above. No extra iPhone app or cloud account is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Device readings") {
                Toggle("Combine matching phone and tablet names", isOn: $combineDuplicates)
                Text("Keeps a personally named phone/tablet in one row across discovery paths. Disable this if distinct devices share the same name. AirPods sides and generic device names stay separate.")
                    .font(.caption).foregroundStyle(.secondary)
                if hub.devices.isEmpty { Text("Waiting for a reported battery reading…").foregroundStyle(.secondary) }
                ForEach(hub.devices) { device in
                    HStack {
                        Label(device.name, systemImage: device.symbol)
                        Spacer()
                        Text(device.usableLevel(at: Date()).map { "\($0)%" + (device.charging ? " · Charging" : "") }
                            ?? (device.connected ? "Reading unavailable" : "Offline")).foregroundStyle(.secondary)
                    }
                }
                Button("Refresh readings") { hub.refresh() }
                if let error = hub.storageError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }.navigationTitle("Batteries & Widgets").onAppear { hub.start(); hub.refresh() }
    }
    private var preview: some View {
        let devices = Array(hub.devices.filter { $0.usableLevel(at: Date()) != nil }.sorted { ($0.level ?? 101) < ($1.level ?? 101) }.prefix(3))
        return Group {
            if devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "circle.hexagongrid").font(.largeTitle).foregroundStyle(.indigo)
                    Text("Your connected batteries will appear here.").foregroundStyle(.secondary)
                }
            } else if previewStyle == "Rings" {
                HStack(spacing: 28) {
                    ForEach(devices) { device in
                        VStack(spacing: 7) {
                            ZStack {
                                Circle().stroke(.primary.opacity(0.1), lineWidth: 5)
                                Circle().trim(from: 0, to: Double(device.level ?? 0) / 100).stroke(tint(device), style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                                Image(systemName: device.symbol).foregroundStyle(tint(device))
                            }.frame(width: 46, height: 46)
                            Text("\(device.level ?? 0)%").font(.system(.body, design: .rounded).weight(.semibold))
                            Text(device.name).font(.caption2).lineLimit(1)
                        }.frame(maxWidth: .infinity)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(devices) { device in
                        VStack(spacing: 5) {
                            HStack { Label(device.name, systemImage: device.symbol); Spacer(); Text("\(device.level ?? 0)%").monospacedDigit() }
                            if previewStyle == "Bars" { ProgressView(value: Double(device.level ?? 0), total: 100).tint(tint(device)) }
                        }
                    }
                }
            }
        }
    }
    private func tint(_ device: OrbitBatteryDevice) -> Color {
        (device.level ?? 100) < 20 ? .red : (device.level ?? 100) <= 30 ? .orange : .green
    }
}
