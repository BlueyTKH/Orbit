import SwiftUI
import Defaults

struct AirPodsBatteryWarningSettings: View {
    @Default(.airPodsBatteryWarningsEnabled) private var enabled
    @Default(.airPodsBatteryWarnings) private var warnings
    @Default(.replaceSystemAirPodsBatteryWarnings) private var replaceSystem
    @ObservedObject private var manager = AirPodsBatteryWarningManager.shared
    @ObservedObject private var accessibility = AccessibilityPermissionStore.shared
    var body: some View {
        Section {
            Toggle("AirPods low-battery warnings", isOn: $enabled)
            VStack(alignment: .leading, spacing: 16) {
                ForEach($warnings) { $warning in
                    AirPodsWarningRow(warning: $warning,
                        occupied: Set(warnings.filter { $0.id != warning.id }.map(\.percentage)),
                        remove: { warnings.removeAll { $0.id == warning.id } })
                    Divider()
                }
                if warnings.isEmpty { Text("Add a warning to choose when your AirPods should alert you.").foregroundStyle(.secondary) }
                Button {
                    let used = Set(warnings.map(\.percentage))
                    guard let level = ([20, 10, 5, 1] + Array((1...99).reversed())).first(where: { !used.contains($0) }) else { return }
                    warnings.append(LowBatteryWarning(percentage: level, duration: 5, presentation: .expanded))
                    warnings.sort { $0.percentage > $1.percentage }
                } label: { Label("Add AirPods warning", systemImage: "plus") }
                .disabled(Set(warnings.map(\.percentage)).count >= 99)
                Toggle("Replace macOS AirPods low-battery pop-ups", isOn: $replaceSystem)
                if replaceSystem && !accessibility.isAuthorized {
                    Text("Allow Orbit in System Settings → Privacy & Security → Accessibility to replace the macOS pop-up. The notch warnings work without it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(!enabled)
            if manager.connectedAirPods.isEmpty {
                Text("Connect your AirPods to see their reported battery levels.").font(.caption).foregroundStyle(.secondary)
            } else if manager.readings.isEmpty {
                Text("AirPods connected. Waiting for a battery reading from macOS.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(manager.readings, id: \.address) { reading in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: reading.name).font(.caption.weight(.semibold))
                        Text(verbatim: reading.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("AirPods Battery Warnings") } footer: {
            Text("Names the low earbud when the levels differ by more than five points; closer levels share an AirPods warning. The lowest discharging earbud triggers each enabled warning once. Charging earbuds and the case are excluded. Recharge three points above a level to reset it. If several levels are crossed together, only the lowest appears. AirPods warnings have no screen-edge glow.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { manager.start(); accessibility.refreshStatus() }
    }
}

private struct AirPodsWarningRow: View {
    @Binding var warning: LowBatteryWarning
    let occupied: Set<Int>
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(warning.percentage)% AirPods warning").fontWeight(.semibold)
                Spacer()
                Toggle("Enable warning", isOn: $warning.enabled).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel("Enable \(warning.percentage) percent AirPods warning")
                Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(warning.percentage) percent AirPods warning")
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker("Battery level", selection: $warning.percentage) {
                    ForEach((1...99).reversed().filter { !occupied.contains($0) || $0 == warning.percentage }, id: \.self) {
                        Text("\($0)%").tag($0)
                    }
                }.pickerStyle(.menu)
                Stepper("Display for \(warning.duration) seconds", value: $warning.duration, in: 1...60)
                Picker("Appearance", selection: $warning.presentation) {
                    Text("Small").tag(LowBatteryWarningPresentation.compact)
                    Text("Expanded").tag(LowBatteryWarningPresentation.expanded)
                }.pickerStyle(.menu)
                Toggle("Play alert sound", isOn: $warning.sound)
                Button { AirPodsBatteryWarningManager.shared.preview(warning: warning) } label: {
                    Label("Preview warning", systemImage: "eye")
                }.buttonStyle(.borderless)
                    .help("Silent preview; leaves your readings and warning history unchanged")
                    .accessibilityLabel("Preview \(warning.percentage) percent AirPods warning")
            }.disabled(!warning.enabled).opacity(warning.enabled ? 1 : 0.5)
        }
    }
}
