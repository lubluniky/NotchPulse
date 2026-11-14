import Foundation

/// Realistic, animating fake data for developing the UI without T3 / sensors.
@MainActor
final class MockDataSource {
    enum Scenario: String {
        case busy       // 2 running, 1 needs input, a few finished
        case calm       // 1 running, nothing waiting
        case idle       // no agents, T3 offline
        case hot        // busy + thermal pressure + low battery
    }

    private weak var model: NotchViewModel?
    private let scenario: Scenario
    private var timer: Timer?
    private var tick = 0
    private var cpu = 0.22
    private var cpuHistory: [Double] = []
    private var memUsed: Double = 11.4 * 1_073_741_824
    private var temp = 52.0
    private var down = 180_000.0
    private var up = 24_000.0
    private var threads: [AgentThread] = []

    init(model: NotchViewModel, scenario: Scenario = .busy) {
        self.model = model
        self.scenario = scenario
        if scenario == .hot { cpu = 0.78; temp = 88 }
        // Pre-fill history so the sparklines look alive immediately.
        for _ in 0..<60 { stepCPU() }
        threads = Self.makeThreads(scenario: scenario, now: Date())
    }

    func start() {
        publish()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: Simulation

    private func stepCPU() {
        let target: Double = scenario == .hot ? 0.8 : (scenario == .idle ? 0.08 : 0.24)
        // Mean-reverting random walk with occasional spikes.
        cpu += (target - cpu) * 0.25 + Double.random(in: -0.07...0.07)
        if Double.random(in: 0...1) < 0.06 { cpu += Double.random(in: 0.15...0.35) }
        cpu = min(0.99, max(0.02, cpu))
        cpuHistory.append(cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
    }

    private func step() {
        tick += 1
        stepCPU()
        memUsed += Double.random(in: -60...70) * 1_048_576
        memUsed = min(15.2 * 1_073_741_824, max(9.5 * 1_073_741_824, memUsed))
        temp += (40 + cpu * 55 - temp) * 0.15 + Double.random(in: -0.6...0.6)
        down = max(0, down * 0.6 + Double.random(in: 0...1) * (Double.random(in: 0...1) < 0.15 ? 6_000_000 : 400_000))
        up = max(0, up * 0.6 + Double.random(in: 0...1) * 90_000)

        // Rotate the running agents' last message so the list feels live.
        if tick % 4 == 0 {
            for i in threads.indices where threads[i].state == .running {
                let lines = Self.runningLines[threads[i].id] ?? []
                if !lines.isEmpty {
                    threads[i].lastMessagePreview = lines[(tick / 4 + i) % lines.count]
                    threads[i].updatedAt = Date()
                }
            }
        }
        publish()
    }

    private func publish() {
        guard let model else { return }
        let memTotal: UInt64 = 16 * 1_073_741_824
        let pressure = min(1, max(0, (memUsed / Double(memTotal) - 0.45) * 1.4))
        let battery: Double = scenario == .hot ? 0.14 : 0.84 - Double(tick) * 0.00002
        let thermal: ThermalLevel = scenario == .hot ? .serious : (temp > 80 ? .fair : .nominal)

        model.system = SystemSnapshot(
            cpuUsage: cpu,
            cpuHistory: cpuHistory,
            memoryUsed: UInt64(memUsed),
            memoryTotal: memTotal,
            memoryPressure: pressure,
            batteryLevel: battery,
            isCharging: scenario == .calm,
            isPluggedIn: scenario == .calm,
            batteryTimeRemaining: scenario == .hot ? 38 : (scenario == .calm ? 52 : 312),
            thermalState: thermal,
            socTemperature: temp,
            netDownBytesPerSec: down,
            netUpBytesPerSec: up)

        let visible = threads
        model.agents = AgentsSnapshot(
            threads: visible,
            runningCount: visible.filter { $0.state == .running }.count,
            needsInputCount: visible.filter { $0.state == .needsInput }.count,
            serverOnline: scenario != .idle,
            lastError: nil)
    }

    // MARK: Fixtures

    private static let runningLines: [String: [String]] = [
        "t-notch": [
            "Updating NotchShape so corner radii animate with the spring.",
            "Spawned 2 subagents to audit hover/click-through handling.",
            "Rendering sparkline with a gradient area fill.",
            "Tweaking wing padding so the orb aligns with the notch curve.",
        ],
        "t-e2e": [
            "Running playwright suite — 14/38 specs passed.",
            "Retrying checkout.spec.ts with tracing enabled.",
            "Found race in cart hydration; adding await for network idle.",
        ],
        "t-search": [
            "Indexing 1,284 documents into the vector store.",
        ],
    ]

    private static func makeThreads(scenario: Scenario, now: Date) -> [AgentThread] {
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        let needs = AgentThread(
            id: "t-auth", title: "Refactor auth middleware to async/await", provider: "claudeAgent",
            model: "claude-opus-5-5", projectName: "atlas-api", state: .needsInput,
            updatedAt: ago(40), runStartedAt: ago(320),
            lastMessagePreview: "I need to clear the build cache before re-running the tests.",
            pendingRequestSummary: "Approve: Bash  rm -rf .build && swift test",
            subagentCount: 0, isSubagent: false)
        let notch = AgentThread(
            id: "t-notch", title: "NotchPulse: polish expanded agent list", provider: "claudeAgent",
            model: "claude-sonnet-5", projectName: "NotchPulse", state: .running,
            updatedAt: ago(5), runStartedAt: ago(252),
            lastMessagePreview: runningLines["t-notch"]![0], pendingRequestSummary: nil,
            subagentCount: 2, isSubagent: false)
        let e2e = AgentThread(
            id: "t-e2e", title: "Fix flaky e2e checkout test", provider: "codex",
            model: "gpt-5.2-codex", projectName: "storefront", state: .running,
            updatedAt: ago(12), runStartedAt: ago(95),
            lastMessagePreview: runningLines["t-e2e"]![0], pendingRequestSummary: nil,
            subagentCount: 0, isSubagent: false)
        let migration = AgentThread(
            id: "t-mig", title: "Write migration for invoices table", provider: "claudeAgent",
            model: "claude-opus-5-5", projectName: "billing", state: .completed,
            updatedAt: ago(12 * 60), runStartedAt: ago(19 * 60),
            lastMessagePreview: "Done — migration 0042 added, 118 tests pass.", pendingRequestSummary: nil,
            subagentCount: 0, isSubagent: false)
        let next = AgentThread(
            id: "t-next", title: "Bump Next.js to 16", provider: "codex",
            model: nil, projectName: "marketing-site", state: .failed,
            updatedAt: ago(41 * 60), runStartedAt: ago(48 * 60),
            lastMessagePreview: "Build failed: Module not found 'next/legacy/image'.", pendingRequestSummary: nil,
            subagentCount: 0, isSubagent: false)
        let docs = AgentThread(
            id: "t-docs", title: "Summarize RFC feedback into a decision doc", provider: "claudeAgent",
            model: "claude-haiku-5", projectName: "rfcs", state: .completed,
            updatedAt: ago(2 * 3600 + 300), runStartedAt: ago(2 * 3600 + 900),
            lastMessagePreview: "Wrote docs/decisions/0017-queue-backpressure.md.", pendingRequestSummary: nil,
            subagentCount: 0, isSubagent: false)
        let search = AgentThread(
            id: "t-search", title: "Prototype semantic search endpoint", provider: "claudeAgent",
            model: "claude-sonnet-5", projectName: "atlas-api", state: .running,
            updatedAt: ago(3), runStartedAt: ago(40),
            lastMessagePreview: runningLines["t-search"]![0], pendingRequestSummary: nil,
            subagentCount: 0, isSubagent: false)

        switch scenario {
        case .busy, .hot: return [needs, notch, e2e, migration, next, docs]
        case .calm:       return [search, migration, docs]
        case .idle:       return []
        }
    }
}
