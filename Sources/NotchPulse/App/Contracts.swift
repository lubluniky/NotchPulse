import Foundation
import Combine

// Interfaces the UI depends on. Concrete classes live in T3/ and System/.
// Both are @MainActor ObservableObjects so SwiftUI can bind directly.
//
//   final class T3Store: ObservableObject      { @Published private(set) var snapshot: AgentsSnapshot; func start(); func stop() }
//   final class SystemMonitor: ObservableObject { @Published private(set) var snapshot: SystemSnapshot; func start(); func stop() }
//
// Also T3Store exposes: func openThread(_ id: String)  // brings T3 Code to front (best effort)
