import Foundation

struct OrbitBatteryDevice: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var level: Int?
    var charging: Bool
    var connected: Bool
    var observedAt: Date
    var detail: String
    var aliases: [String]? = nil
    func usableLevel(at date: Date) -> Int? {
        guard connected, date.timeIntervalSince(observedAt) <= 180, date >= observedAt.addingTimeInterval(-5),
              let level, (0...100).contains(level) else { return nil }
        return level
    }
}
struct OrbitBatterySnapshot: Codable, Equatable, Sendable {
    var schema = 1
    var writtenAt: Date
    var devices: [OrbitBatteryDevice]
    func selected(ids: [String], at date: Date) -> [OrbitBatteryDevice] {
        if !ids.isEmpty {
            var seen = Set<String>()
            return ids.compactMap { id in devices.first { $0.id == id || ($0.aliases ?? []).contains(id) } }
                .filter { seen.insert($0.id).inserted }
        }
        return devices.filter { $0.usableLevel(at: date) != nil }.sorted {
            let left = $0.usableLevel(at: date) ?? 101, right = $1.usableLevel(at: date) ?? 101
            return left == right ? $0.id < $1.id : left < right
        }
    }
}
enum OrbitBatteryStore {
    #if DEBUG
    static let group = "7BTPSB6L83.com.kayhsen.Orbit.Development"
    #else
    static let group = "7BTPSB6L83.com.kayhsen.Orbit"
    #endif
    static let widgetKind = "OrbitBatteries"
    static func url() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Batteries/snapshot.json")
    }
    static func read() -> OrbitBatterySnapshot? {
        guard let url = url(), let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(OrbitBatterySnapshot.self, from: data), value.schema == 1 else { return nil }
        return value
    }
    static func write(_ snapshot: OrbitBatterySnapshot) throws {
        guard let url = url() else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
