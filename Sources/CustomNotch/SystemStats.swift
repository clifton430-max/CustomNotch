import Darwin
import IOKit.ps
import SwiftUI

/// Memory split the way Activity Monitor reports it, in bytes.
struct MemoryBreakdown: Equatable {
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var total: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var swapUsed: Double = 0
    /// 0 when memory is plentiful, approaching 1 under heavy pressure.
    var pressure: Double = 0

    var used: Double { app + wired + compressed }
}

/// Battery, CPU and memory readings. They refresh live only while the notch is open (see
/// `setLive`); otherwise the last values stay put and only battery changes, which macOS
/// announces, are picked up.
@MainActor
final class SystemStats: ObservableObject {
    @Published private(set) var battery: Double = 1
    @Published private(set) var isCharging = false
    @Published private(set) var onAC = false
    @Published private(set) var cpu: Double = 0
    @Published private(set) var memory: Double = 0
    @Published private(set) var cpuUser: Double = 0
    @Published private(set) var cpuSystem: Double = 0
    /// Recent total CPU readings, oldest first (about two minutes' worth).
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryBreakdown = MemoryBreakdown()

    private var lastTicks: [UInt32]?
    private var timer: Timer?
    private var isLive = false
    private var powerSource: CFRunLoopSource?

    init() {
        refresh()
        // The collapsed notch shows battery, so follow power changes without polling.
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let stats = Unmanaged<SystemStats>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { stats.readBattery() }
        }, context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
    }

    /// Starts or pauses live polling. Resuming refreshes battery and memory at once and takes
    /// a fresh CPU reading a moment later, so nothing is shown averaged over the pause.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        timer?.invalidate()
        timer = nil
        guard live else { return }

        readBattery()
        readMemory()
        lastTicks = currentTicks()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLive else { return }
                self.refresh()
                let repeating = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                repeating.tolerance = 0.3
                RunLoop.main.add(repeating, forMode: .common)
                self.timer = repeating
            }
        }
    }

    var batteryPercent: Int { Int((battery * 100).rounded()) }

    var batterySymbol: String {
        if isCharging || onAC { return "battery.100percent.bolt" }
        switch battery {
        case 0.88...: return "battery.100percent"
        case 0.63...: return "battery.75percent"
        case 0.38...: return "battery.50percent"
        case 0.13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var batteryTint: Color {
        if isCharging || onAC { return Color(red: 0.30, green: 0.85, blue: 0.45) }
        return battery < 0.2 ? Color(red: 1, green: 0.32, blue: 0.3) : .white
    }

    var batteryStatus: String {
        if isCharging { return "Charging" }
        if onAC { return "Power Adapter" }
        return "On Battery"
    }

    private func refresh() {
        readBattery()
        readCPU()
        readMemory()
    }

    private func readBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            battery = Double(current) / Double(max)
            isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            onAC = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return
        }
    }

    private func readCPU() {
        guard let ticks = currentTicks() else { return }
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return }
        let delta = zip(ticks, last).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return }
        // Order is user, system, idle, nice.
        cpu = (total - delta[2]) / total
        cpuUser = (delta[0] + delta[3]) / total
        cpuSystem = delta[1] / total
        cpuHistory.append(cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
    }

    private func currentTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        var breakdown = MemoryBreakdown()
        breakdown.app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * page
        breakdown.wired = Double(stats.wire_count) * page
        breakdown.compressed = Double(stats.compressor_page_count) * page
        breakdown.cached = (Double(stats.external_page_count) + Double(stats.purgeable_count)) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            breakdown.swapUsed = Double(swap.xsu_used)
        }
        var level: Int32 = 100
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &levelSize, nil, 0) == 0 {
            breakdown.pressure = max(0, min(1, 1 - Double(level) / 100))
        }

        memoryBreakdown = breakdown
        memory = min(1, breakdown.used / breakdown.total)
    }
}
