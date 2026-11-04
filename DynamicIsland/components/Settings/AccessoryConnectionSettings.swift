import SwiftUI
import Defaults

struct AccessoryConnectionSettings: View {
    @Default(.showBluetoothDeviceConnections) private var showConnections
    @Default(.showAirPodsDisconnections) private var showDisconnections
    @Default(.airPodsConnectionStyle) private var connectionStyle
    @Default(.airPodsDisconnectionStyle) private var disconnectionStyle
    @Default(.airPodsConnectionDuration) private var airPodsDuration
    @Default(.showMouseConnections) private var showMouse
    @Default(.mouseConnectionStyle) private var mouseStyle
    @Default(.mouseConnectionDuration) private var mouseDuration
    @ObservedObject private var manager = AccessoryConnectionManager.shared
    var body: some View {
        Section {
            stylePicker("Connection appearance", selection: $connectionStyle).disabled(!showConnections)
            Toggle("Show AirPods disconnections", isOn: $showDisconnections).disabled(!showConnections)
            stylePicker("Disconnection appearance", selection: $disconnectionStyle).disabled(!showConnections || !showDisconnections)
            Stepper("Display for \(airPodsDuration) seconds", value: $airPodsDuration, in: 1...60).disabled(!showConnections)
            HStack(spacing: 16) {
                Button { manager.preview(kind: .airPods, connected: true, style: connectionStyle) } label: {
                    Label("Preview connection", systemImage: "eye")
                }.accessibilityLabel("Preview AirPods connection")
                Button { manager.preview(kind: .airPods, connected: false, style: disconnectionStyle) } label: {
                    Label("Preview disconnection", systemImage: "eye")
                }.accessibilityLabel("Preview AirPods disconnection")
            }.buttonStyle(.borderless)
        } header: { Text("AirPods Connection Alerts") } footer: {
            Text("Small shows the left and right charge separately beside the camera. Expanded adds your device name and connection status. Disconnections show the last reported levels. Listening-mode controls keep their existing appearance.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Show mouse connections", isOn: $showMouse)
            stylePicker("Connection appearance", selection: $mouseStyle).disabled(!showMouse)
            Stepper("Display for \(mouseDuration) seconds", value: $mouseDuration, in: 1...60).disabled(!showMouse)
            Button { manager.preview(kind: .mouse, connected: true, style: mouseStyle) } label: {
                Label("Preview mouse connection", systemImage: "eye")
            }.buttonStyle(.borderless).accessibilityLabel("Preview mouse connection")
            ForEach(manager.connectedMice, id: \.address) { mouse in
                LabeledContent(mouse.name, value: mouse.main.map { "\($0)%" } ?? "Battery unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Mouse Connection Alerts") } footer: {
            Text("Shows the battery charge reported by macOS when a Bluetooth mouse connects. The circular indicator and percentage-text switches above also apply here. Unknown readings stay unavailable.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { manager.start() }
    }
    private func stylePicker(_ title: String, selection: Binding<BatteryNotificationStyle>) -> some View {
        Picker(title, selection: selection) {
            Text("Small").tag(BatteryNotificationStyle.compact)
            Text("Expanded").tag(BatteryNotificationStyle.standard)
        }.pickerStyle(.menu)
    }
}
