import SwiftUI
import Defaults

struct LowBatteryWarningsSettings: View {
    @Default(.lowBatteryWarnings) private var warnings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach($warnings) { $warning in
                LowBatteryWarningRow(warning: $warning,
                    occupiedPercentages: Set(warnings.filter { $0.id != warning.id }.map(\.percentage)),
                    remove: { warnings.removeAll { $0.id == warning.id } })
                Divider()
            }
            if warnings.isEmpty {
                Text("No low-battery warnings. Add one to choose when to be notified.")
                    .foregroundStyle(.secondary)
            }
            Button {
                guard let percentage = LowBatteryWarning.nextPercentage(in: warnings) else { return }
                warnings.append(LowBatteryWarning(percentage: percentage))
                warnings.sort { $0.percentage > $1.percentage }
            } label: {
                Label("Add warning", systemImage: "plus")
            }
            .disabled(LowBatteryWarning.nextPercentage(in: warnings) == nil)
            Text("Warnings appear once as the battery falls through each percentage. Charging at least two points above a warning resets it. If several levels are crossed together, only the most urgent warning appears.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LowBatteryWarningRow: View {
    @Binding var warning: LowBatteryWarning
    let occupiedPercentages: Set<Int>
    let remove: () -> Void
    @Default(.playLowBatteryAlertSound) private var playAlertSound

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(warning.percentage)% warning").fontWeight(.semibold)
                Spacer()
                Toggle("Enable warning", isOn: $warning.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable \(warning.percentage) percent warning")
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this warning")
                .accessibilityLabel("Remove \(warning.percentage) percent warning")
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker("Battery level", selection: $warning.percentage) {
                    ForEach((1...99).reversed().filter { !occupiedPercentages.contains($0) || $0 == warning.percentage }, id: \.self) {
                        Text("\($0)%").tag($0)
                    }
                }
                .pickerStyle(.menu)
                Stepper("Display for \(warning.duration) seconds", value: $warning.duration, in: 1...60)
                Picker("Appearance", selection: $warning.presentation) {
                    ForEach(LowBatteryWarningPresentation.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Play alert sound", isOn: $warning.sound)
                    .disabled(!playAlertSound)
                if warning.presentation == .critical {
                    Text("A larger red warning and a soft red glow around the screen edges ask you to connect power immediately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    BatteryStatusViewModel.shared.triggerTestLowBatteryWarning(warning)
                } label: {
                    Label("Preview warning", systemImage: "eye")
                }
                .buttonStyle(.borderless)
                .help("Shows this warning without changing the battery or playing its sound")
                .accessibilityLabel("Preview \(warning.percentage) percent warning")
            }
            .disabled(!warning.enabled)
            .opacity(warning.enabled ? 1 : 0.5)
        }
    }
}
