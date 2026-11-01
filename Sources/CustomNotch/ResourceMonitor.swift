import AppKit
import Darwin
import IOKit
import IOKit.ps

enum ResourceKind: String, CaseIterable, Identifiable {
    case cpu, memory, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .battery: "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .battery: "battery.75percent"
        }
    }
}

/// One application (with all of its helper processes) or one standalone process.
struct AppUsage: Identifiable, Equatable {
    enum Kind: Equatable { case app, system, background }

    let id: String
    let name: String
    /// The outermost `.app` bundle, when the process belongs to one.
    let bundlePath: String?
    let kind: Kind
    /// Percent of one core, as Activity Monitor shows it (400% = four busy cores).
    var cpu: Double
    /// Physical footprint in bytes.
    var memory: Double
    var processCount: Int

    var detail: String {
        switch kind {
        case .app: processCount == 1 ? "Application" : "Application · \(processCount) processes"
        case .system: processCount == 1 ? "System process" : "System · \(processCount) processes"
        case .background: processCount == 1 ? "Background process" : "Background · \(processCount) processes"
        }
    }
}

struct BatteryDetails: Equatable {
    var percent: Double = 0
    var isCharging = false
    var isPluggedIn = false
    var isFullyCharged = false
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    /// Watts flowing into (+) or out of (−) the battery.
    var batteryWatts: Double?
    /// What the whole Mac is drawing right now, when the battery reports it.
    var systemWatts: Double?
    var adapterWatts: Int?
    var cycleCount: Int?
    var maxCapacityPercent: Int?
    var designCapacity: Int?
    var fullChargeCapacity: Int?
    var voltage: Double?
    var temperature: Double?
    var isLowPowerMode = false
}

/// Samples per-process CPU and memory, plus detailed battery information, while a detail
/// panel is on screen.
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var battery: BatteryDetails?
    @Published private(set) var hasBattery = true
    @Published private(set) var lastUpdated: Date?

    private var timer: Timer?
    private var isSampling = false
    private var iconCache: [String: NSImage] = [:]

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func icon(for app: AppUsage) -> NSImage? {
        guard let path = app.bundlePath else { return nil }
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    private func refresh() {
        guard !isSampling else { return }
        isSampling = true
        Task.detached(priority: .utility) {
            let apps = Self.sampleProcesses()
            let battery = Self.readBattery()
            await MainActor.run {
                self.apps = apps
                self.battery = battery
                self.hasBattery = battery != nil
                self.lastUpdated = Date()
                self.isSampling = false
            }
        }
    }

    // MARK: Processes

    private nonisolated static func sampleProcesses() -> [AppUsage] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Aceo", "pid=,pcpu=,rss=,uid=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var groups: [String: AppUsage] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int32(fields[0]), let cpu = Double(fields[1]),
                  let rss = Double(fields[2]), let uid = Int(fields[3]) else { continue }
            let command = String(fields[4])
            let memory = footprint(of: pid) ?? rss * 1024

            let path = executablePath(of: pid)
            if let bundle = path.flatMap(outermostBundle) {
                let name = FileManager.default.displayName(atPath: bundle).replacingOccurrences(of: ".app", with: "")
                groups[bundle, default: AppUsage(id: bundle, name: name, bundlePath: bundle, kind: .app,
                                                 cpu: 0, memory: 0, processCount: 0)].add(cpu: cpu, memory: memory)
            } else {
                let key = "proc:\(command)"
                let kind: AppUsage.Kind = uid == 0 || uid < 500 ? .system : .background
                groups[key, default: AppUsage(id: key, name: command, bundlePath: nil, kind: kind,
                                              cpu: 0, memory: 0, processCount: 0)].add(cpu: cpu, memory: memory)
            }
        }
        return Array(groups.values)
    }

    private nonisolated static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/…" → "/Applications/Foo.app",
    /// so helpers are counted with the app that owns them.
    private nonisolated static func outermostBundle(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private nonisolated static func footprint(of pid: Int32) -> Double? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Double(info.ri_phys_footprint) : nil
    }

    // MARK: Battery

    private nonisolated static func readBattery() -> BatteryDetails? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let info = list.lazy.compactMap({
                  IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
              }).first(where: { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }) else { return nil }

        var details = BatteryDetails()
        if let current = info[kIOPSCurrentCapacityKey] as? Int, let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
            details.percent = Double(current) / Double(max)
        }
        details.isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
        details.isPluggedIn = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        details.isFullyCharged = info[kIOPSIsChargedKey] as? Bool ?? false
        if let toFull = info[kIOPSTimeToFullChargeKey] as? Int, toFull > 0 { details.minutesToFull = toFull }
        let estimate = IOPSGetTimeRemainingEstimate()
        if estimate > 0 { details.minutesToEmpty = Int(estimate / 60) }
        details.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            details.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard service != 0,
              IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let registry = properties?.takeRetainedValue() as? [String: Any] else { return details }
        let nested = registry["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Int64? {
            ((registry[key] ?? nested[key]) as? NSNumber)?.int64Value
        }

        details.cycleCount = number("CycleCount").map { Int($0) }
        if let design = number("DesignCapacity"), design > 0 {
            details.designCapacity = Int(design)
            if let full = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity") {
                details.fullChargeCapacity = Int(full)
                details.maxCapacityPercent = Int((Double(full) / Double(design) * 100).rounded())
            }
        }
        if let mv = number("Voltage") {
            details.voltage = Double(mv) / 1000
            // The registry reports discharge current as a wrapped unsigned value.
            if let raw = (registry["Amperage"] as? NSNumber)?.uint64Value {
                let ma = Double(Int64(bitPattern: raw))
                details.batteryWatts = Double(mv) / 1000 * ma / 1000
            }
        }
        if let telemetry = registry["PowerTelemetryData"] as? [String: Any],
           let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            details.systemWatts = load / 1000
        } else if let watts = details.batteryWatts, watts < 0 {
            details.systemWatts = -watts
        }
        if let temp = number("Temperature") ?? number("VirtualTemperature"), temp > 0 {
            details.temperature = Double(temp) / 100
        }
        return details
    }
}

private extension AppUsage {
    mutating func add(cpu: Double, memory: Double) {
        self.cpu += cpu
        self.memory += memory
        processCount += 1
    }
}
