import Foundation

/// Display/storage rebrand only. The bundle ID and keychain services stay stable.
/// Existing directories move atomically; conflicts are retained, never overwritten.
enum OrbitDataMigration {
    private struct Report {
        var paths: [UInt: URL] = [:]
        var errors: [String] = []
    }
    private static let report: Report = {
        var result = Report()
        let manager = FileManager.default
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory, .cachesDirectory] {
            guard let base = manager.urls(for: directory, in: .userDomainMask).first else { continue }
            #if DEBUG
            // Development/test launches must never migrate the installed app's data.
            let developmentBase = directory == .documentDirectory
                ? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit Development/Documents")
                : base.appendingPathComponent("Orbit Development")
            try? manager.createDirectory(at: developmentBase, withIntermediateDirectories: true)
            result.paths[directory.rawValue] = developmentBase
            #else
            let old = base.appendingPathComponent("NotchFlow", isDirectory: true)
            let destination = base.appendingPathComponent("Orbit", isDirectory: true)
            do {
                try migrate(from: old, to: destination)
                result.paths[directory.rawValue] = destination
            } catch {
                // Keep working from the untouched legacy directory if the move fails.
                result.paths[directory.rawValue] = manager.fileExists(atPath: old.path) ? old : destination
                result.errors.append(String(describing: error))
            }
            #endif
        }
        return result
    }()
    static var hasErrors: Bool { !report.errors.isEmpty }
    static func directory(_ kind: FileManager.SearchPathDirectory) -> URL {
        report.paths[kind.rawValue] ?? FileManager.default.temporaryDirectory.appendingPathComponent("Orbit")
    }
    static func prepare() { _ = report }
    static func migrate(from old: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path) else {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true); return
        }
        guard manager.fileExists(atPath: destination.path) else { try manager.moveItem(at: old, to: destination); return }
        try merge(old, into: destination, recovery: destination.appendingPathComponent("Migration Recovered"))
    }
    private static func merge(_ old: URL, into destination: URL, recovery: URL) throws {
        let manager = FileManager.default
        for source in try manager.contentsOfDirectory(at: old, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            var sourceDirectory: ObjCBool = false, targetDirectory: ObjCBool = false
            manager.fileExists(atPath: source.path, isDirectory: &sourceDirectory)
            if !manager.fileExists(atPath: target.path, isDirectory: &targetDirectory) {
                try manager.moveItem(at: source, to: target)
            } else if sourceDirectory.boolValue && targetDirectory.boolValue {
                try merge(source, into: target, recovery: recovery)
            } else if manager.contentsEqual(atPath: source.path, andPath: target.path) {
                try manager.removeItem(at: source) // Identical data remains at destination.
            } else {
                // Preserve both versions for arbitrary notes/icons/other saved files.
                try manager.createDirectory(at: recovery, withIntermediateDirectories: true)
                let recovered = recovery.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
                if source.lastPathComponent == "samples.json", source.deletingLastPathComponent().lastPathComponent == "BatteryHistory",
                   let left = try? JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [[String: Any]],
                   let right = try? JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [[String: Any]],
                   (left + right).allSatisfy({ $0["date"] is NSNumber }) {
                    var records: [Double: [String: Any]] = [:]
                    for value in left + right { records[(value["date"] as! NSNumber).doubleValue] = value }
                    let combined = records.keys.sorted().compactMap { records[$0] }
                    try JSONSerialization.data(withJSONObject: combined).write(to: target, options: .atomic)
                }
                try manager.moveItem(at: source, to: recovered)
            }
        }
        if try manager.contentsOfDirectory(atPath: old.path).isEmpty { try manager.removeItem(at: old) }
    }
}
