import AppKit
import AVFoundation
import Combine
import Defaults
import SwiftUI

enum BreakReminderPhase: Equatable {
    case idle, invited, resting, completed
    var showsPreview: Bool { self == .invited || self == .completed }
    var keepsNotchClosed: Bool { showsPreview }
}

/// A scheduled reminder is an invitation, never an automatically started rest.
struct BreakReminderSession: Equatable {
    private(set) var phase: BreakReminderPhase = .idle
    private(set) var invitationDeadline: Date?
    private(set) var breakDeadline: Date?
    private(set) var dismissDeadline: Date?

    mutating func invite(now: Date) {
        guard phase == .idle else { return }
        invitationDeadline = now.addingTimeInterval(20)
        phase = .invited
    }
    mutating func start(now: Date, duration: TimeInterval) {
        guard phase == .invited else { return }
        guard let invitationDeadline, now < invitationDeadline else { dismiss(); return }
        self.invitationDeadline = nil
        breakDeadline = now.addingTimeInterval(max(1, duration))
        phase = .resting
    }
    /// Returns true only on the transition that completes an accepted break.
    @discardableResult
    mutating func advance(now: Date) -> Bool {
        if phase == .invited, let deadline = invitationDeadline, now >= deadline {
            skip()
        } else if phase == .resting, let deadline = breakDeadline, now >= deadline {
            phase = .completed
            // Give a newly visible completion its full ten seconds, even when
            // the countdown expired during sleep or a busy run loop.
            dismissDeadline = now.addingTimeInterval(10)
            return true
        } else if phase == .completed, let deadline = dismissDeadline, now >= deadline {
            dismiss()
        }
        return false
    }
    mutating func skip() {
        guard phase == .invited else { return }
        dismiss()
    }
    mutating func done() {
        guard phase == .completed else { return }
        dismiss()
    }
    mutating func dismiss() { self = Self() }
}

/// Break-only envelope; other activities keep their existing sizes.
enum BreakReminderLayout {
    static let previewHeight: CGFloat = 78
    static func size(phase: BreakReminderPhase, isOpen: Bool, closedSize: CGSize, openSize: CGSize) -> CGSize {
        guard phase != .idle else { return isOpen ? openSize : closedSize }
        if isOpen { return openSize }
        return CGSize(width: phase.showsPreview ? max(340, closedSize.width + 140) : closedSize.width + 160,
                      height: closedSize.height + (phase.showsPreview ? previewHeight : 0))
    }
}

/// Deadlines, rather than tick counts, remain correct across sleep and busy run loops.
@MainActor
final class BreakReminderManager: NSObject, ObservableObject {
    static let shared = BreakReminderManager()
    @Published private(set) var session = BreakReminderSession()
    var phase: BreakReminderPhase { session.phase }
    var breakDeadline: Date? { session.breakDeadline }
    @Published private(set) var now = Date()
    private(set) var breakDuration: TimeInterval = 20
    private var workDeadline: Date?
    private var timer: Timer?
    private var completionSoundPlayer: AVAudioPlayer?
    private var subscriptions = Set<AnyCancellable>()
    private var inactive = false
    var secondsRemaining: Int { Self.remaining(until: breakDeadline, now: now) }
    var canFinish: Bool { phase == .completed }
    nonisolated static func remaining(until deadline: Date?, now: Date) -> Int {
        guard let deadline else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }
    nonisolated static func progress(until deadline: Date?, duration: TimeInterval, now: Date) -> Double {
        guard let deadline, duration > 0 else { return 0 }
        return min(1, max(0, 1 - deadline.timeIntervalSince(now) / duration))
    }
    nonisolated static func yieldsToHUD(show: Bool, type: SneakContentType) -> Bool {
        show && type != .recording
    }
    private override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        Defaults.publisher(.breakReminderEnabled, options: []).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configure() }.store(in: &subscriptions)
        Defaults.publisher(.breakWorkMinutes, options: []).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resetWork() }.store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.inactive = true }
                .store(in: &subscriptions)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }; self.inactive = false
                self.now = Date(); self.resetWork(); self.tick()
            }.store(in: &subscriptions)
        }
        configure()
    }
    private func configure() {
        timer?.invalidate(); timer = nil
        if !Defaults[.breakReminderEnabled] {
            completionSoundPlayer?.stop()
            session.dismiss(); workDeadline = nil
            return
        }
        resetWork()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    @objc private func screenLocked(_ notification: Notification) { inactive = true }
    @objc private func screenUnlocked(_ notification: Notification) {
        inactive = false; now = Date(); resetWork(); tick()
    }
    private func resetWork() {
        workDeadline = Defaults[.breakReminderEnabled] ? Date().addingTimeInterval(Double(max(1, Defaults[.breakWorkMinutes])) * 60) : nil
    }
    private func tick() {
        guard !inactive else { return }
        now = Date()
        advanceSession()
        guard Defaults[.breakReminderEnabled], phase == .idle,
              let deadline = workDeadline, now >= deadline else { return }
        requestBreak()
    }
    private func advanceSession() {
        var updated = session
        let didComplete = updated.advance(now: now)
        guard updated != session else { return }
        session = updated
        if didComplete { playCompletionSound() }
        if phase == .idle {
            completionSoundPlayer?.stop()
            resetWork()
        }
    }
    func requestBreak() {
        guard Defaults[.breakReminderEnabled], phase == .idle else { return }
        workDeadline = nil
        now = Date()
        session.invite(now: now)
    }
    func startBreak() {
        guard Defaults[.breakReminderEnabled] else { return }
        now = Date()
        advanceSession()
        guard phase == .invited else { return }
        breakDuration = Double(max(1, Defaults[.breakDurationSeconds]))
        session.start(now: now, duration: breakDuration)
    }
    func skip() {
        guard phase == .invited else { return }
        session.skip()
        resetWork()
    }
    func finish() {
        now = Date()
        advanceSession()
        guard canFinish else { return }
        session.done()
        completionSoundPlayer?.stop()
        resetWork()
    }

    private func playCompletionSound() {
        // Honour the existing timer sound choice without starting or changing
        // a TimerManager session. Eye-break completion is a single cue.
        let customPath = UserDefaults.standard.string(forKey: "customTimerSoundPath")
        let customURL = customPath.flatMap { path in
            !path.isEmpty && FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard let url = customURL ?? Bundle.main.url(forResource: "timer", withExtension: "mp3")
                ?? Bundle.main.url(forResource: "dynamic", withExtension: "m4a") else {
            NSSound.beep()
            return
        }
        do {
            completionSoundPlayer = try AVAudioPlayer(contentsOf: url)
            completionSoundPlayer?.numberOfLoops = 0
            if completionSoundPlayer?.play() != true { NSSound.beep() }
        } catch {
            NSSound.beep()
        }
    }
}

struct BreakReminderNotchView: View {
    @ObservedObject private var reminder = BreakReminderManager.shared
    @EnvironmentObject private var vm: DynamicIslandViewModel
    let phase: BreakReminderPhase
    var compact = false
    var body: some View {
        if compact && phase.showsPreview {
            Color.clear.frame(height: vm.effectiveClosedNotchHeight)
        } else if compact {
            HStack(spacing: 0) {
                Label("Rest", systemImage: "eye").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.mint).frame(width: 80)
                Color.clear.frame(width: vm.closedNotchSize.width)
                Group {
                    if (phase == .completed) {
                        Button("Done") { reminder.finish() }.buttonStyle(.plain).foregroundStyle(.mint)
                            .accessibilityLabel("Complete rest break")
                    } else {
                        Text("\(reminder.secondsRemaining)s").monospacedDigit().foregroundStyle(.white)
                    }
                }.font(.system(size: 13, weight: .semibold)).frame(width: 80)
            }.frame(height: vm.effectiveClosedNotchHeight)
        } else if phase.showsPreview && vm.notchState == .closed {
            VStack(alignment: .leading, spacing: 8) {
                Label(phase == .invited ? "Time for a short break" : "Break complete",
                      systemImage: phase == .invited ? "eye" : "checkmark.circle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.mint)
                HStack(spacing: 8) {
                    Text(phase == .invited ? "Rest your eyes for a moment." : "Ready when you are.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    if phase == .invited {
                        previewButton("Skip", prominent: false) { reminder.skip() }
                        previewButton("Start", prominent: true) { reminder.startBreak() }
                    } else {
                        previewButton("Done", prominent: true) { reminder.finish() }
                    }
                }
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 16) {
                if phase == .resting {
                    progressRing
                } else {
                    Image(systemName: phase == .invited ? "eye" : "checkmark.circle")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.mint)
                        .frame(width: 40)
                }
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(phase == .invited ? "Time for a short break" : (phase == .completed) ? "Break complete" : "Rest your eyes")
                            .font(.system(size: phase.showsPreview ? 15 : 18, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(phase == .invited ? "Start when you’re ready, or skip this break." : (phase == .completed) ? "Ready when you are." : "Look at something in the distance and relax your shoulders.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if phase == .invited {
                        HStack(spacing: 10) {
                            breakButton("Skip", symbol: "forward.end.fill", prominent: false) { reminder.skip() }
                            breakButton("Start", symbol: "play.fill", prominent: true) { reminder.startBreak() }
                        }
                    } else if phase == .completed {
                        breakButton("Done", symbol: "checkmark", prominent: true) { reminder.finish() }
                    }
                }
            }
            .padding(.horizontal, phase.showsPreview ? 25 : 12)
            .padding(.vertical, phase.showsPreview ? 15 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(prominent ? .black : .white)
                .frame(width: 46, height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(prominent ? Color.mint.opacity(0.8) : Color.white.opacity(0.12), in: Capsule())
    }

    private var progressRing: some View {
        let progress = BreakReminderManager.progress(until: reminder.breakDeadline, duration: reminder.breakDuration, now: reminder.now)
        return ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 4)
            Circle().trim(from: 0, to: progress)
                .stroke(.mint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            VStack(spacing: 3) {
                Image(systemName: (phase == .completed) ? "checkmark" : "eye")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.mint)
                Text("\(reminder.secondsRemaining)s")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.smooth(duration: 0.2), value: reminder.secondsRemaining)
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((phase == .completed) ? "Eye break complete" : "\(reminder.secondsRemaining) seconds remaining")
    }

    private func breakButton(_ title: String, symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(prominent ? 1 : 0.9))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(prominent ? Color.mint.opacity(0.65) : Color.white.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(prominent ? 0.15 : 0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Keep the break header/body mounted while the shell opens and closes. Only
/// the countdown leaf views observe clock ticks, so they cannot reset the shell.
struct BreakReminderNotchLayout: View {
    @EnvironmentObject private var vm: DynamicIslandViewModel
    let phase: BreakReminderPhase
    private var showsBody: Bool { vm.notchState == .open || phase.showsPreview }
    private var contentHeight: CGFloat {
        vm.notchState == .open ? max(0, openNotchSize.height - vm.effectiveClosedNotchHeight - 36) : BreakReminderLayout.previewHeight
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                DynamicIslandHeader()
                    .opacity(vm.notchState == .open ? 1 : 0)
                    .allowsHitTesting(vm.notchState == .open)
                BreakReminderNotchView(phase: phase, compact: true)
                    .opacity(vm.notchState == .closed ? 1 : 0)
                    .allowsHitTesting(vm.notchState == .closed)
            }
            .frame(height: max(24, vm.effectiveClosedNotchHeight))
            BreakReminderNotchView(phase: phase)
                .frame(height: contentHeight)
                .opacity(showsBody ? 1 : 0)
                .frame(height: showsBody ? contentHeight : 0, alignment: .top)
                .clipped()
                .allowsHitTesting(showsBody)
        }
        .frame(height: vm.notchState == .closed && !phase.showsPreview ? vm.effectiveClosedNotchHeight : nil, alignment: .top)
    }
}

/// Keep one clip modifier mounted through break/HUD handoffs and preserve the
/// selected shape's own animation data. Interpolating a separate notch shape
/// while drawing an unchanged fallback makes its corners snap during opening.
struct BreakReminderClipModifier: ViewModifier {
    let isActive: Bool
    let notchShape: NotchShape
    let fallback: AnyShape
    var resolvedShape: AnyShape { isActive ? AnyShape(notchShape) : fallback }
    func body(content: Content) -> some View {
        content.clipShape(resolvedShape)
    }
}
