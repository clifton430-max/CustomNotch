import Darwin
import IOKit.ps
import SwiftUI

/// Battery, CPU and memory readings, refreshed every couple of seconds.
@MainActor
final class SystemStats: ObservableObject {
    @Published private(set) var battery: Double = 1
    @Published private(set) var isCharging = false
    @Published private(set) var onAC = false
    @Published private(set) var cpu: Double = 0
    @Published private(set) var memory: Double = 0

    private var lastTicks: [UInt32]?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
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
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return }
        let delta = zip(ticks, last).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return }
        // Order is user, system, idle, nice.
        cpu = (total - delta[2]) / total
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
        let pages = Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)
        let used = pages * Double(vm_kernel_page_size)
        memory = min(1, used / Double(ProcessInfo.processInfo.physicalMemory))
    }
}
