import SwiftUI
import Defaults
import KeyboardShortcuts

struct NotchFlowUtilitiesSettingsSections: View {
    @Default(.breakReminderEnabled) private var enabled
    @Default(.breakWorkMinutes) private var workMinutes
    @Default(.breakDurationSeconds) private var restSeconds
    @Default(.snapSplitRatio) private var split
    var body: some View {
        Section {
            Defaults.Toggle(key: .breakReminderEnabled) { Text("Break reminders") }
            if enabled {
                Stepper("Remind every \(workMinutes) minutes", value: $workMinutes, in: 1...120, step: 1)
                Stepper("Rest for \(restSeconds) seconds", value: $restSeconds, in: 5...600, step: 5)
                Button("Take a break now") { BreakReminderManager.shared.requestBreak() }
            }
        } header: { Text("Rest & wellbeing") } footer: {
            Text("A notch preview invites you to Start or Skip. An unanswered reminder is skipped after 20 seconds. Start begins the rest timer; a sound plays when it finishes. Done dismisses the completion preview, or it closes automatically after 10 seconds. Sleep and lock time do not trigger overdue reminders.")
        }
        Section {
            Defaults.Toggle(key: .snapDragEnabled) { Text("Show layouts when dragging a window near the notch") }
            Picker("Window split", selection: $split) {
                Text("Equal halves").tag(0.5)
                Text("Larger left side").tag(0.6)
                Text("Larger right side").tag(0.4)
            }
            Button("Arrange windows") { WindowSnapManager.shared.show() }
            KeyboardShortcuts.Recorder("Left", name: .notchSnapLeft)
            KeyboardShortcuts.Recorder("Right", name: .notchSnapRight)
            KeyboardShortcuts.Recorder("Fill screen", name: .notchSnapFill)
            KeyboardShortcuts.Recorder("Restore", name: .notchSnapRestore)
        } header: { Text("Window snapping") } footer: {
            Text("Drag a window near the top centre to reveal layouts below the notch; drag onto a layout and release. Hold Command to bypass. Four actions use the display’s usable area, avoiding the menu bar and Dock. Requires Accessibility; shortcuts are optional.")
        }
    }
}
