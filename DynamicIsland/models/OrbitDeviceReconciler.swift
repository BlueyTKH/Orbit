import Foundation
import CryptoKit

/// Optional, conservative consolidation of personally named phones/tablets.
/// Generic names and accessory components are deliberately kept separate.
enum OrbitDeviceReconciler {
    static func phoneKey(name: String, symbol: String? = nil) -> String? {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !["airpods", "keyboard", "mouse", "trackpad", "pencil", "beats"].contains(where: normalized.contains),
              !["iphone", "ipad", "ipad pro", "ipad air", "ipad mini"].contains(normalized) else { return nil }
        if let symbol, !["ipad", "iphone", "headphones", "wave.3.right"].contains(symbol) { return nil }
        let family = symbol == "ipad" || normalized.contains("ipad") ? "ipad" : symbol == "iphone" || normalized.contains("iphone") ? "iphone" : nil
        return family.map { $0 + ":" + normalized }
    }
    static func reconcile(_ records: [OrbitBatteryDevice], combine: Bool, at date: Date) -> [OrbitBatteryDevice] {
        let groups = Dictionary(grouping: records) { record in
            combine ? phoneKey(name: record.name, symbol: record.symbol).map { "phone:" + $0 } ?? "id:" + record.id : "id:" + record.id
        }
        return groups.map { key, members in
            var best = members.sorted { lhs, rhs in
                let leftLive = lhs.usableLevel(at: date) != nil, rightLive = rhs.usableLevel(at: date) != nil
                if leftLive != rightLive { return leftLive }
                if lhs.connected != rhs.connected { return lhs.connected }
                if abs(lhs.observedAt.timeIntervalSince(rhs.observedAt)) > 60 { return lhs.observedAt > rhs.observedAt }
                let leftRank = rank(lhs.id), rightRank = rank(rhs.id)
                if leftRank != rightRank { return leftRank > rightRank }
                if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
                return lhs.id < rhs.id
            }.first!
            if key.hasPrefix("phone:") {
                best.id = "phone:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                best.aliases = Array(Set(members.flatMap { [$0.id] + ($0.aliases ?? []) }).subtracting([best.id])).sorted()
            }
            return best
        }.sorted { $0.id < $1.id }
    }
    static func discoveryCandidates(_ records: [NearbyBatteryCandidate], lastSeen: [String: Date], tracked: Set<String>, combine: Bool, at date: Date) -> [NearbyBatteryCandidate] {
        let fresh = records.filter { date.timeIntervalSince(lastSeen[$0.id] ?? .distantPast) <= 90 }
        let groups = Dictionary(grouping: fresh) { combine ? phoneKey(name: $0.name) ?? $0.id : $0.id }
        return groups.values.compactMap { group in
            group.sorted { lhs, rhs in
                if tracked.contains(lhs.id) != tracked.contains(rhs.id) { return tracked.contains(lhs.id) }
                if lastSeen[lhs.id] != lastSeen[rhs.id] { return (lastSeen[lhs.id] ?? .distantPast) > (lastSeen[rhs.id] ?? .distantPast) }
                return lhs.id < rhs.id
            }.first
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
    static func isPhoneInventoryID(_ id: String) -> Bool {
        ["phone:", "mobile:", "nearby:"].contains { id.hasPrefix($0) }
    }
    static func menuRows(_ rows: [BatteryMenuDevice], combine: Bool, at date: Date) -> [BatteryMenuDevice] {
        let records = rows.map { row in
            OrbitBatteryDevice(id: row.id, name: row.name, symbol: row.symbol, level: row.level,
                charging: false, connected: true, observedAt: date, detail: row.detail)
        }
        return reconcile(records, combine: combine, at: date).map {
            BatteryMenuDevice(id: $0.id, name: $0.name, symbol: $0.symbol, detail: $0.detail, level: $0.level)
        }
    }
    private static func rank(_ id: String) -> Int { id.hasPrefix("phone:") ? 4 : id.hasPrefix("mobile:") ? 3 : id.hasPrefix("nearby:") ? 2 : 1 }
}
