import Foundation
import CoreFoundation
import Defaults

/// Separate components prevent a full case/high earbud from masking a low bud.
struct AirPodsBatteryReading: Equatable, Sendable {
    let address: String
    let name: String
    let symbol: String
    var left: Int?
    var right: Int?
    var main: Int?
    var leftCharging = false
    var rightCharging = false
    var mainCharging = false
    let observedAt: Date

    var listeningLevel: Int? {
        if left != nil || right != nil {
            return [leftCharging ? nil : left, rightCharging ? nil : right].compactMap { $0 }.min()
        }
        return mainCharging ? nil : main
    }
    var lowSide: AirPodsLowBatterySide {
        let left = leftCharging ? nil : left
        let right = rightCharging ? nil : right
        switch (left, right) {
        case let (.some(left), .some(right)):
            if abs(left - right) <= 5 { return .together }
            return left < right ? .left : .right
        case (.some, .none): return .left
        case (.none, .some): return .right
        case (.none, .none): return .device
        }
    }
    var recoveryLevel: Int? { [left, right].compactMap { $0 }.min() ?? main }
    var detail: String {
        var parts: [String] = []
        if let left { parts.append("Left \(left)%" + (leftCharging ? " · Charging" : "")) }
        if let right { parts.append("Right \(right)%" + (rightCharging ? " · Charging" : "")) }
        if parts.isEmpty, let main { parts.append("\(main)% remaining") }
        return parts.joined(separator: "  ·  ")
    }
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= 65
    }

    static func decode(_ payload: [String: Any], address: String, name: String,
                       symbol: String, observedAt: Date) -> Self? {
        func level(_ keys: [String]) -> Int? {
            keys.lazy.compactMap { payload[$0].flatMap(percentage) }.first
        }
        func charging(_ keys: [String]) -> Bool {
            for key in keys {
                if let number = payload[key] as? NSNumber { return number.boolValue }
                if let text = payload[key] as? String { return ["yes", "true", "charging", "1"].contains(text.lowercased()) }
            }
            return false
        }
        let left = level(["BatteryPercentLeft", "device_batteryLevelLeft", "Left Battery Level"])
        let right = level(["BatteryPercentRight", "device_batteryLevelRight", "Right Battery Level"])
        // Never fall back to Case, or to a merged old device.batteryLevel value.
        let main = level(["BatteryPercentSingle", "BatteryPercentMain", "BatteryPercent", "BatteryPercentCombined",
                          "device_batteryLevelMain", "device_batteryLevel", "device_batteryLevelCombined", "Battery Level", "BatteryLevel"])
        guard left != nil || right != nil || main != nil else { return nil }
        return Self(address: address, name: name, symbol: symbol, left: left, right: right, main: main,
                    leftCharging: charging(["BatteryIsChargingLeft", "BatteryChargingLeft", "IsChargingLeft", "device_batteryChargingLeft"]),
                    rightCharging: charging(["BatteryIsChargingRight", "BatteryChargingRight", "IsChargingRight", "device_batteryChargingRight"]),
                    mainCharging: charging(["BatteryIsCharging", "BatteryCharging", "IsCharging", "device_batteryCharging"]),
                    observedAt: observedAt)
    }

    static func percentage(_ raw: Any) -> Int? {
        let value: Double?
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            value = number.doubleValue
        } else if let string = raw as? String {
            value = Double(string.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
        } else { value = nil }
        // Percent-labelled fields use 0...100. In particular, 1 means 1%, not 100%.
        guard let value, value.isFinite, (0...100).contains(value), value.rounded() == value else { return nil }
        return Int(value)
    }

    func previewing(level: Int) -> Self {
        var result = self
        switch (left, right) {
        case let (.some(left), .some(right)):
            result.left = min(100, level + max(0, left - right))
            result.right = min(100, level + max(0, right - left))
            result.main = nil
        case (.some, .none): result.left = level; result.main = nil
        case (.none, .some): result.right = level; result.main = nil
        case (.none, .none): result.main = level
        }
        result.leftCharging = false; result.rightCharging = false; result.mainCharging = false
        return result
    }

    static let preview = Self(address: "preview", name: "AirPods Pro", symbol: "airpods.pro",
                              left: 20, right: 24, main: nil, observedAt: Date())
}

enum AirPodsLowBatterySide: Equatable {
    case left, right, together, device
    var compactTitle: String {
        switch self {
        case .left: return "Left AirPod"
        case .right: return "Right AirPod"
        case .together, .device: return "AirPods"
        }
    }
    var expandedTitle: String {
        switch self {
        case .left: return "Left AirPod Low"
        case .right: return "Right AirPod Low"
        case .together: return "AirPods Low"
        case .device: return "Low Battery"
        }
    }
}

struct AirPodsBatteryWarningTracker {
    private(set) var delivered: Set<String> = []
    static func key(address: String, threshold: Int) -> String {
        address.lowercased().filter { $0.isLetter || $0.isNumber } + ":\(threshold)"
    }
    mutating func recover(_ reading: AirPodsBatteryReading, threshold: Int, now: Date) {
        guard reading.isFresh(at: now), let level = reading.recoveryLevel, level >= min(threshold + 3, 100) else { return }
        delivered.remove(Self.key(address: reading.address, threshold: threshold))
    }
    func shouldWarn(_ reading: AirPodsBatteryReading, threshold: Int, now: Date) -> Bool {
        reading.isFresh(at: now) && (1...99).contains(threshold)
            && reading.listeningLevel.map { $0 <= threshold } == true
            && !delivered.contains(Self.key(address: reading.address, threshold: threshold))
    }
    mutating func markDelivered(_ reading: AirPodsBatteryReading, threshold: Int) {
        delivered.insert(Self.key(address: reading.address, threshold: threshold))
    }
}

enum AirPodsBatteryWarningLayout {
    static func surface(closed: CGSize, style: BatteryNotificationStyle) -> CGSize {
        CGSize(width: closed.width + (style == .compact ? 180 : 150),
               height: closed.height + (style == .compact ? 0 : 75))
    }
}

enum AirPodsNativeReplacementAction { case queueAndDismiss, dismissDuplicate, presentAndDismiss }

enum AirPodsNativeWarningReplayPolicy {
    static func action(delivered: Bool, hasMeasuredReading: Bool, lastPresentation: Date?, canPresent: Bool, now: Date) -> AirPodsNativeReplacementAction {
        if !shouldPresent(delivered: delivered, hasMeasuredReading: hasMeasuredReading, lastPresentation: lastPresentation, now: now) {
            return .dismissDuplicate
        }
        return canPresent ? .presentAndDismiss : .queueAndDismiss
    }
    static func shouldPresent(delivered: Bool, hasMeasuredReading: Bool, lastPresentation: Date?, now: Date) -> Bool {
        if hasMeasuredReading && delivered { return false }
        // Without component readings, recovery cannot be inferred. Keep native
        // warnings available, while coalescing repeated/retried popups quietly.
        let cooldown: TimeInterval = hasMeasuredReading ? 60 : 300
        return now.timeIntervalSince(lastPresentation ?? .distantPast) >= cooldown
    }
}

/// Match the exact native low-battery label, a connected device and a small popup.
/// Normal connection/listening-mode popups and larger settings panels do not match.
enum AirPodsNativeLowBatteryMatcher {
    static let owners = Set(["com.apple.controlcenter", "com.apple.BluetoothUIService", "com.apple.BluetoothUIServer"])
    static func match(owner: String, texts: [String], width: CGFloat, height: CGFloat,
                      readings: [AirPodsBatteryReading], labels: [String], aliases: [String: [String]] = [:], excludedLabels: [String] = ["Case Low Battery"], now: Date) -> AirPodsBatteryReading? {
        guard owners.contains(owner), (100...650).contains(width), (28...190).contains(height),
              texts.contains(where: { text in labels.contains { label in
                  let text = normalized(text); let label = normalized(label)
                  return !label.isEmpty && (text == label || text.hasPrefix(label + " ") || text.hasSuffix(" " + label))
              }}), !texts.contains(where: { text in excludedLabels.contains { normalized(text).contains(normalized($0)) } }) else { return nil }
        let normalizedTexts = texts.map(normalized)
        let candidates = readings.filter { reading in
            let names = ([reading.name] + (aliases[reading.address] ?? [])).map(normalized).filter { !$0.isEmpty }
            let hasName = names.contains { name in
                normalizedTexts.contains { text in
                    text == name || text.hasPrefix(name + " ") || text.hasPrefix(name + ",")
                }
            }
            return reading.isFresh(at: now) && hasName
        }
        // Two pairs with identical names cannot be identified from the popup.
        return candidates.count == 1 ? candidates.first : nil
    }

    static func readingFromPopup(_ reading: AirPodsBatteryReading, texts: [String], now: Date) -> AirPodsBatteryReading? {
        // The native ring is a live source, even if the last cache sample was higher
        // or macOS hasn't exposed earbud components to System Profiler yet.
        let percentages = texts.compactMap { text -> Int? in
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text != reading.name else { return nil }
            if text.range(of: "^[0-9]{1,3}%?$", options: .regularExpression) != nil {
                return AirPodsBatteryReading.percentage(text)
            }
            guard let range = text.range(of: "(?<![0-9])[0-9]{1,3}%", options: .regularExpression) else { return nil }
            return AirPodsBatteryReading.percentage(String(text[range]))
        }.filter { $0 <= 20 }
        guard let level = percentages.min() ?? reading.listeningLevel.flatMap({ $0 <= 20 ? $0 : nil }) else { return nil }
        if reading.left != nil || reading.right != nil {
            guard !(reading.leftCharging && reading.rightCharging) else { return nil }
        } else if reading.mainCharging { return nil }
        if reading.listeningLevel == level {
            return AirPodsBatteryReading(address: reading.address, name: reading.name, symbol: reading.symbol,
                left: reading.left, right: reading.right, main: reading.main,
                leftCharging: reading.leftCharging, rightCharging: reading.rightCharging, mainCharging: reading.mainCharging, observedAt: now)
        }
        return AirPodsBatteryReading(address: reading.address, name: reading.name, symbol: reading.symbol,
            left: nil, right: nil, main: level, observedAt: now)
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}


/// Same editable warning rows as the Mac, without Critical/screen effects.
enum AirPodsWarningConfiguration {
    static func initial(threshold: Int, duration: Int, style: BatteryNotificationStyle, sound: Bool) -> [LowBatteryWarning] {
        let original = LowBatteryWarning(percentage: min(max(threshold, 1), 99),
            duration: min(max(duration, 1), 60), presentation: style == .compact ? .compact : .expanded, sound: sound)
        // Preserve the existing warning exactly; new lower levels remain opt-in.
        return [original]
    }
    static func normalized(_ warnings: [LowBatteryWarning]) -> [LowBatteryWarning] {
        LowBatteryWarning.normalized(warnings).map {
            var warning = $0
            if warning.presentation == .critical { warning.presentation = .expanded }
            return warning
        }
    }
}

extension AirPodsBatteryWarningTracker {
    func nextWarning(_ reading: AirPodsBatteryReading, warnings: [LowBatteryWarning], now: Date) -> LowBatteryWarning? {
        AirPodsWarningConfiguration.normalized(warnings).first { shouldWarn(reading, threshold: $0.percentage, now: now) }
    }
    mutating func markDelivered(_ reading: AirPodsBatteryReading, warnings: [LowBatteryWarning], now: Date) {
        // A large drop/low reconnect shows the most urgent level once, instead
        // of replaying every higher warning in successive HUDs.
        for warning in AirPodsWarningConfiguration.normalized(warnings)
            where shouldWarn(reading, threshold: warning.percentage, now: now) {
            markDelivered(reading, threshold: warning.percentage)
        }
    }
}
