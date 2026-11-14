import Combine
import Dispatch
import Foundation

/// Publishes a `SystemSnapshot` for the UI.
///
/// Sampling runs on a private utility-QoS serial queue driven by a DispatchSourceTimer with
/// generous leeway (lets the OS coalesce wakeups); only the merge + publish happens on main.
/// Interval: 1 s while `fastMode` (UI expanded), 3 s otherwise. Temperature is read at most
/// every 2 s, battery at most every 5 s – plus instantly on IOPS plug/unplug notifications.
/// Thermal state also updates instantly via `thermalStateDidChangeNotification`.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot = .empty

    /// true → sample every 1 s (UI expanded); false → every 3 s (battery friendly).
    var fastMode: Bool = false {
        didSet {
            guard fastMode != oldValue, isRunning else { return }
            // Going fast: show fresh numbers almost immediately. Going slow: next tick in 3 s.
            scheduleTimer(initialDelay: fastMode ? 0.3 : Self.slowInterval)
        }
    }

    static let fastInterval: TimeInterval = 1
    static let slowInterval: TimeInterval = 3
    static let historyLength = 60

    private(set) var isRunning = false

    private let queue = DispatchQueue(label: "NotchPulse.SystemMonitor.sampling", qos: .utility)
    private let sampler = SystemSampler()          // only touched on `queue`
    private var history: [Double] = []
    private var generation: UInt64 = 0             // drops samples that straddle stop()/start()

    // nonisolated(unsafe): mutated only on the main actor; deinit needs to reach them.
    nonisolated(unsafe) private var timer: DispatchSourceTimer?
    nonisolated(unsafe) private var powerObserver: PowerSourceObserver?
    nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?

    init() {
        // Never expose a 0 total (UI may divide by it) even before the first sample lands.
        snapshot.memoryTotal = ProcessInfo.processInfo.physicalMemory
    }

    deinit {
        timer?.cancel()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1

        powerObserver = PowerSourceObserver { [weak self] in
            // IOPS run-loop source lives on the main run loop.
            MainActor.assumeIsolated { self?.applyPower(PowerSourceReader.read()) }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyThermal(ProcessInfo.processInfo.thermalState) }
        }

        // Prime CPU/network baselines and publish memory/battery/thermal/temperature right away
        // as one snapshot (CPU and network follow on the first timer tick).
        let deliver = makeDeliver()
        queue.async { [sampler] in
            sampler.reset()
            deliver(sampler.sample())
        }

        let timer = Self.makeTimer(queue: queue, sampler: sampler, deliver: deliver)
        self.timer = timer
        scheduleTimer(initialDelay: fastMode ? 0.5 : 1.0)
        timer.resume()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        timer?.cancel()
        timer = nil
        powerObserver = nil
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
    }

    // MARK: - Private

    private func scheduleTimer(initialDelay: TimeInterval) {
        let interval = fastMode ? Self.fastInterval : Self.slowInterval
        timer?.schedule(deadline: .now() + initialDelay,
                        repeating: interval,
                        leeway: .milliseconds(fastMode ? 100 : 500))
    }

    /// A @Sendable hop from the sampling queue to the main actor, tagged with the current session.
    private func makeDeliver() -> @Sendable (SystemSample) -> Void {
        let generation = self.generation
        return { [weak self] sample in
            let monitor = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { monitor?.apply(sample, generation: generation) }
            }
        }
    }

    /// Built outside the main actor so the handler closure is not main-actor isolated.
    nonisolated private static func makeTimer(queue: DispatchQueue,
                                              sampler: SystemSampler,
                                              deliver: @escaping @Sendable (SystemSample) -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        timer.setEventHandler { deliver(sampler.sample()) }
        return timer
    }

    private func apply(_ sample: SystemSample, generation: UInt64) {
        guard isRunning, generation == self.generation else { return }
        var next = snapshot
        if let cpu = sample.cpu {
            history.append(cpu)
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
            next.cpuUsage = cpu
            next.cpuHistory = history
        }
        if let memory = sample.memory {
            next.memoryUsed = memory.used
            next.memoryTotal = memory.total
            next.memoryPressure = memory.pressure
        }
        if let power = sample.power { Self.merge(power, into: &next) }
        if sample.temperatureWasRead { next.socTemperature = sample.temperature }
        if let network = sample.network {
            next.netDownBytesPerSec = network.downBytesPerSec
            next.netUpBytesPerSec = network.upBytesPerSec
        }
        next.thermalState = sample.thermal
        if next != snapshot { snapshot = next }
    }

    private func applyPower(_ power: PowerReading) {
        guard isRunning else { return }
        var next = snapshot
        Self.merge(power, into: &next)
        if next != snapshot { snapshot = next }
    }

    private func applyThermal(_ state: ProcessInfo.ThermalState) {
        guard isRunning else { return }
        let level = ThermalLevel(state)
        if snapshot.thermalState != level { snapshot.thermalState = level }
    }

    private static func merge(_ power: PowerReading, into snapshot: inout SystemSnapshot) {
        snapshot.batteryLevel = power.batteryLevel
        snapshot.isCharging = power.isCharging
        snapshot.isPluggedIn = power.isPluggedIn
        snapshot.batteryTimeRemaining = power.batteryTimeRemaining
    }
}

extension ThermalLevel {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

// MARK: - Background sampling

/// One sampling pass; nil fields mean "no new value this pass, keep the previous one".
struct SystemSample: Sendable {
    var cpu: Double?
    var memory: MemoryReading?
    var power: PowerReading?
    var thermal: ThermalLevel
    var temperatureWasRead: Bool
    var temperature: Double?
    var network: NetworkThroughput?
}

/// Owns all stateful samplers. Confined to SystemMonitor's serial queue (hence @unchecked).
final class SystemSampler: @unchecked Sendable {
    private let cpu = CPULoadSampler()
    private let memory = MemorySampler()
    private let network = NetworkThroughputSampler()
    private lazy var temperature = SoCTemperatureReader()

    private var lastTemperatureRead: UInt64 = 0    // ns, CLOCK_MONOTONIC; 0 = never
    private var lastPowerRead: UInt64 = 0

    private static let temperatureInterval: UInt64 = 1_900_000_000   // ~2 s (slack for timer leeway)
    private static let powerInterval: UInt64 = 4_900_000_000         // ~5 s

    func reset() {
        cpu.reset()
        network.reset()
        lastTemperatureRead = 0
        lastPowerRead = 0
    }

    func sample() -> SystemSample {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)

        var sample = SystemSample(cpu: cpu.sample(),
                                  memory: memory.sample(),
                                  power: nil,
                                  thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
                                  temperatureWasRead: false,
                                  temperature: nil,
                                  network: network.sample())

        if lastTemperatureRead == 0 || now &- lastTemperatureRead >= Self.temperatureInterval {
            lastTemperatureRead = now
            sample.temperatureWasRead = true
            sample.temperature = temperature.read()
        }
        if lastPowerRead == 0 || now &- lastPowerRead >= Self.powerInterval {
            lastPowerRead = now
            sample.power = PowerSourceReader.read()
        }
        return sample
    }
}
