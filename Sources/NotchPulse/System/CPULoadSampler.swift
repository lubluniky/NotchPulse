import Darwin

/// Total CPU usage from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas.
/// Not thread-safe: confine to one queue.
final class CPULoadSampler {
    private let host = mach_host_self()
    private var previousTicks: [UInt32] = []

    /// Forget the baseline so the next `sample()` re-primes (e.g. after stop/start).
    func reset() { previousTicks.removeAll(keepingCapacity: true) }

    /// Usage 0...1 across all cores since the previous call.
    /// Returns nil on the first call (no baseline yet) or if the kernel call fails.
    func sample() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            // The kernel hands us a freshly vm_allocate'd array; it must be returned.
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let statesPerCPU = Int(CPU_STATE_MAX)
        let count = min(Int(cpuCount) * statesPerCPU, Int(infoCount))
        var current = [UInt32](repeating: 0, count: count)
        for i in 0..<count { current[i] = UInt32(bitPattern: info[i]) }

        defer { previousTicks = current }
        guard previousTicks.count == current.count, count > 0 else { return nil }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for base in stride(from: 0, to: count, by: statesPerCPU) {
            // natural_t tick counters can wrap; wrapping subtraction keeps deltas right.
            let user = UInt64(current[base + Int(CPU_STATE_USER)] &- previousTicks[base + Int(CPU_STATE_USER)])
            let system = UInt64(current[base + Int(CPU_STATE_SYSTEM)] &- previousTicks[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(current[base + Int(CPU_STATE_NICE)] &- previousTicks[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(current[base + Int(CPU_STATE_IDLE)] &- previousTicks[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(busy) / Double(total)))
    }
}
