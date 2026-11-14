import Darwin
import Foundation

struct MemoryReading: Equatable, Sendable {
    var used: UInt64
    var total: UInt64
    var pressure: Double
}

/// Memory usage via `host_statistics64(HOST_VM_INFO64)` plus kernel memorystatus sysctls.
///
/// used = (internal − purgeable + wired + compressor) × pagesize, i.e. Activity Monitor's
/// "Memory Used" = App Memory + Wired Memory + Compressed.
///
/// pressure: `1 − kern.memorystatus_level / 100` (the kernel's "system-wide memory free
/// percentage", the same number `memory_pressure` prints and Activity Monitor's pressure
/// graph tracks), then clamped into the band of the kernel's discrete pressure state
/// `kern.memorystatus_vm_pressure_level` (1 normal → ≤ 0.59, 2 warn → 0.60…0.89,
/// 4 critical → ≥ 0.90). That keeps the value continuous for a bar/gauge while UI colour
/// thresholds at 0.6 / 0.9 match Activity Monitor's green / yellow / red exactly.
/// Fallbacks: level-only mapping 0.2 / 0.6 / 0.95, then used/total.
final class MemorySampler {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let total = ProcessInfo.processInfo.physicalMemory

    init() {
        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 {
            pageSize = UInt64(size)
        } else {
            pageSize = UInt64(sysconf(_SC_PAGESIZE) > 0 ? sysconf(_SC_PAGESIZE) : 16_384)
        }
    }

    func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let usedPages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let used = min(usedPages * pageSize, total)

        return MemoryReading(used: used, total: total, pressure: pressure(used: used))
    }

    private func pressure(used: UInt64) -> Double {
        let level = Self.sysctlInt32("kern.memorystatus_vm_pressure_level")
        let band: ClosedRange<Double>
        switch level {
        case 4?: band = 0.90...1.0
        case 2?: band = 0.60...0.89
        default: band = 0.0...0.59
        }
        if let freePercent = Self.sysctlInt32("kern.memorystatus_level"), (0...100).contains(freePercent) {
            let raw = 1 - Double(freePercent) / 100
            return min(band.upperBound, max(band.lowerBound, raw))
        }
        switch level {
        case 4?: return 0.95
        case 2?: return 0.6
        case 1?: return 0.2
        default: return total > 0 ? min(1, Double(used) / Double(total)) : 0
        }
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        return value
    }
}
