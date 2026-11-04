import AppKit
import Combine
import Defaults

struct BatteryHistorySample: Codable, Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let level: Int
    let charging: Bool
    let pluggedIn: Bool
    let watts: Double?
    let volts: Double?
    let amps: Double?
    let cycles: Int?
    let health: Int?
}

@MainActor
final class BatteryHistoryManager: ObservableObject {
    static let shared = BatteryHistoryManager()
    nonisolated static let batterySupported = MacBatteryManager.shared.currentDiagnostics().hasBattery
    @Published private(set) var samples: [BatteryHistorySample] = []
    @Published private(set) var status: MacBatteryManager.BatteryStatus?
    @Published private(set) var diagnostics = MacBatteryManager.BatteryDiagnostics.unavailable
    @Published private(set) var health: MacBatteryManager.SystemHealthReport?
    @Published private(set) var storageError: String?
    private let worker = DispatchQueue(label: "com.kayhsen.NotchFlow.battery-history", qos: .utility)
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var reading = false
    private var healthReading = false
    private var viewers = Set<UUID>()
    private var lastWrite = Date.distantPast
    private let fileURL: URL

    private init() {
        fileURL = OrbitDataMigration.directory(.applicationSupportDirectory)
            .appendingPathComponent("BatteryHistory/samples.json")
        let url = fileURL
        worker.async { [weak self] in
            let records = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([BatteryHistorySample].self, from: $0) } ?? []
            Task { @MainActor in
                guard let self else { return }
                self.samples = Self.retained(records + self.samples, now: Date())
            }
        }
        Defaults.publisher(.statsUpdateInterval, options: []).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.save() }.store(in: &subscriptions)
        schedule()
        refresh()
    }

    nonisolated static func retained(_ records: [BatteryHistorySample], now: Date) -> [BatteryHistorySample] {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        var dates = Set<Date>()
        return Array(records.filter { $0.date >= cutoff && $0.date <= now && dates.insert($0.date).inserted }
            .sorted { $0.date < $1.date }.suffix(43_200))
    }

    nonisolated static func timeDomain(hours: Int, now: Date) -> ClosedRange<Date> {
        now.addingTimeInterval(-Double(max(1, hours)) * 3600)...now
    }

    nonisolated static func samples(_ records: [BatteryHistorySample], in domain: ClosedRange<Date>) -> [BatteryHistorySample] {
        records.filter { domain.contains($0.date) }
    }

    func setVisible(_ visible: Bool, token: UUID) {
        if visible { viewers.insert(token) } else { viewers.remove(token) }
        schedule()
        if visible { refresh(); refreshHealth() }
    }

    private func schedule() {
        timer?.invalidate()
        let interval = viewers.isEmpty ? 60 : min(60, max(1, Defaults[.statsUpdateInterval]))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        worker.async { [weak self] in
            let status = MacBatteryManager.shared.currentStatus()
            let diagnostics = MacBatteryManager.shared.currentDiagnostics()
            Task { @MainActor in
                guard let self else { return }
                self.reading = false
                if self.status != status { self.status = status }
                if self.diagnostics != diagnostics { self.diagnostics = diagnostics }
                guard let level = status.percentage else { return }
                let now = Date()
                guard now.timeIntervalSince(self.samples.last?.date ?? .distantPast) >= 60 else { return }
                self.samples.append(BatteryHistorySample(date: now, level: level,
                    charging: status.isCharging, pluggedIn: status.isPluggedIn,
                    watts: diagnostics.batteryPowerWatts, volts: diagnostics.voltageVolts,
                    amps: diagnostics.currentAmps, cycles: diagnostics.cycleCount,
                    health: self.health?.maximumCapacityPercent ?? diagnostics.calculatedHealthPercent))
                self.samples = Self.retained(self.samples, now: now)
                if now.timeIntervalSince(self.lastWrite) >= 300 { self.save() }
            }
        }
    }

    func refreshHealth() {
        guard !healthReading else { return }
        healthReading = true
        worker.async { [weak self] in
            let report = MacBatteryManager.shared.systemHealthReport()
            Task { @MainActor in
                self?.health = report
                self?.healthReading = false
            }
        }
    }

    func save() {
        let records = samples
        let url = fileURL
        lastWrite = Date()
        worker.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(records).write(to: url, options: .atomic)
                Task { @MainActor in self?.storageError = nil }
            } catch {
                Task { @MainActor in self?.storageError = "History could not be saved: \(error.localizedDescription)" }
            }
        }
    }
}
