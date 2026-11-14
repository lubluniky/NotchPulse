import Foundation

/// Command-line flags.
///
///   --mock                     use MockDataSource instead of live data
///   --mock-scenario=<name>     busy (default) | calm | idle | hot   (implies --mock)
///   --expanded                 force the island open (screenshots / design work)
struct LaunchOptions {
    var useMock: Bool
    var scenario: MockDataSource.Scenario
    var forceExpanded: Bool

    /// The app runs on live data unless `--mock` / `--mock-scenario=` is passed.
    static let liveDataAvailable = true

    init(arguments: [String] = CommandLine.arguments) {
        let args = arguments.dropFirst()
        forceExpanded = args.contains("--expanded")

        var scenario = MockDataSource.Scenario.busy
        var scenarioGiven = false
        if let raw = args.first(where: { $0.hasPrefix("--mock-scenario=") })?
            .split(separator: "=", maxSplits: 1).last,
           let s = MockDataSource.Scenario(rawValue: String(raw)) {
            scenario = s
            scenarioGiven = true
        }
        self.scenario = scenario
        useMock = !Self.liveDataAvailable || args.contains("--mock") || scenarioGiven
    }
}
