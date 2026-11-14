import Foundation

// MARK: - Shared contracts between data layers and UI.
// Data layers (T3Store, SystemMonitor) publish these; UI only reads them.

/// What an agent thread is doing right now.
enum AgentState: String, Equatable, Sendable {
    case running        // a run is in progress
    case needsInput     // waiting on the user (approval / question / pending runtime request)
    case completed      // last run finished OK
    case failed         // last run errored / was interrupted
    case idle           // no runs yet / unknown
}

struct AgentThread: Identifiable, Equatable, Sendable {
    let id: String              // thread_id
    var title: String
    var provider: String        // e.g. "claudeAgent", "codex" (raw from T3)
    var model: String?          // e.g. "claude-opus-5-5" if available
    var projectName: String?
    var state: AgentState
    var updatedAt: Date
    var runStartedAt: Date?     // when the current/last run started
    var lastMessagePreview: String?   // last assistant (or user) text, single line, trimmed
    var pendingRequestSummary: String? // e.g. "Approve: Bash rm -rf build" when needsInput
    var subagentCount: Int      // running subagents under this thread
    var isSubagent: Bool        // thread itself is a subagent of another
}

struct AgentsSnapshot: Equatable, Sendable {
    var threads: [AgentThread]   // sorted: needsInput, done/failed in last 30m, running, then older by recency
    var runningCount: Int
    var needsInputCount: Int
    var serverOnline: Bool       // T3 server process reachable / runtime file fresh
    var lastError: String?
    static let empty = AgentsSnapshot(threads: [], runningCount: 0, needsInputCount: 0, serverOnline: false, lastError: nil)
}

struct SystemSnapshot: Equatable, Sendable {
    var cpuUsage: Double          // 0...1, total across cores
    var cpuHistory: [Double]      // last ~60 samples, 0...1
    var memoryUsed: UInt64        // bytes (app + wired + compressed)
    var memoryTotal: UInt64       // bytes
    var memoryPressure: Double    // 0...1
    var batteryLevel: Double?     // 0...1, nil if no battery
    var isCharging: Bool
    var isPluggedIn: Bool
    var batteryTimeRemaining: Int? // minutes, nil if unknown/calculating
    var thermalState: ThermalLevel
    var socTemperature: Double?   // °C, best effort, nil if unavailable
    var netDownBytesPerSec: Double
    var netUpBytesPerSec: Double
    static let empty = SystemSnapshot(cpuUsage: 0, cpuHistory: [], memoryUsed: 0, memoryTotal: 0, memoryPressure: 0, batteryLevel: nil, isCharging: false, isPluggedIn: false, batteryTimeRemaining: nil, thermalState: .nominal, socTemperature: nil, netDownBytesPerSec: 0, netUpBytesPerSec: 0)
}

enum ThermalLevel: String, Equatable, Sendable { case nominal, fair, serious, critical }
