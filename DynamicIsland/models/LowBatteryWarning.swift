import Foundation
import Defaults

enum LowBatteryWarningPresentation: String, Codable, CaseIterable, Identifiable {
    case compact, expanded, critical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "Small"
        case .expanded: return "Expanded"
        case .critical: return "Critical"
        }
    }
    var priority: Int { self == .critical ? 2 : self == .expanded ? 1 : 0 }
    var style: BatteryNotificationStyle { self == .compact ? .compact : .standard }
}

struct LowBatteryWarning: Codable, Equatable, Identifiable, Defaults.Serializable {
    var id: UUID = UUID()
    var percentage: Int
    var duration: Int = 3
    var presentation: LowBatteryWarningPresentation = .compact
    var enabled: Bool = true
    var sound: Bool = true

    static let defaults: [Self] = [
        Self(percentage: 15), Self(percentage: 10), Self(percentage: 5),
        Self(percentage: 1, duration: 10, presentation: .critical)
    ]

    static func initialWarnings(legacyThreshold: Int?, legacyDuration: Int, legacyStyle: BatteryNotificationStyle) -> [Self] {
        var result = defaults
        // Preserve an explicitly customized old threshold as an extra warning.
        if let threshold = legacyThreshold, threshold != 20, (1...99).contains(threshold) {
            let legacy = Self(percentage: threshold, duration: min(max(legacyDuration, 1), 60),
                              presentation: legacyStyle == .compact ? .compact : .expanded)
            result.removeAll { $0.percentage == threshold }
            result.append(legacy)
        }
        return result.sorted { $0.percentage > $1.percentage }
    }

    static func normalized(_ warnings: [Self]) -> [Self] {
        var seen = Set<Int>()
        return warnings.filter { $0.enabled && (1...99).contains($0.percentage) }
            .sorted {
                if $0.percentage != $1.percentage { return $0.percentage < $1.percentage }
                // For malformed/imported duplicate thresholds, keep the urgent
                // variant deterministically and never generate duplicate alerts.
                if $0.presentation != $1.presentation { return $0.presentation.priority > $1.presentation.priority }
                return $0.id.uuidString < $1.id.uuidString
            }
            .filter { seen.insert($0.percentage).inserted }
            .map { warning in
                var clamped = warning
                clamped.duration = min(max(warning.duration, 1), 60)
                return clamped
            }
    }

    static func nextPercentage(in warnings: [Self]) -> Int? {
        let used = Set(warnings.map(\.percentage))
        return ([20, 25, 30, 40, 50] + Array((1...99).reversed())).first { !used.contains($0) }
    }
}

/// Crossing-based alerts, once per threshold until charging recovers above it.
struct LowBatteryWarningTracker {
    private(set) var delivered = Set<Int>()

    mutating func resetRecoveredWarnings(at level: Float) {
        guard level.isFinite, (0...100).contains(level) else { return }
        delivered = delivered.filter { level < Float($0 + 2) }
    }

    mutating func update(previous: Float, current: Float, connectedToPower: Bool,
                         warnings: [LowBatteryWarning]) -> LowBatteryWarning? {
        guard previous.isFinite, current.isFinite, (0...100).contains(current),
              (0...100).contains(previous) else { return nil }
        if connectedToPower {
            // Two points of recovery avoid repeating on noisy boundary readings.
            resetRecoveredWarnings(at: current)
            return nil
        }
        guard current < previous else { return nil }
        let crossed = LowBatteryWarning.normalized(warnings).filter {
            previous > Float($0.percentage) && current <= Float($0.percentage)
                && !delivered.contains($0.percentage)
        }
        delivered.formUnion(crossed.map(\.percentage))
        // A sleep-time drop can cross several levels. Show only the lowest one.
        return crossed.first
    }
}
