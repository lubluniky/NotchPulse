import SwiftUI

// MARK: - Palette

enum Palette {
    static let running   = Color(red: 0.188, green: 0.820, blue: 0.345)   // #30D158
    static let attention = Color(red: 1.000, green: 0.624, blue: 0.039)   // #FF9F0A
    static let failed    = Color(red: 1.000, green: 0.271, blue: 0.227)   // #FF453A
    static let completed = Color.white.opacity(0.45)
    static let idle      = Color.white.opacity(0.25)

    static let cpu       = Color(red: 0.392, green: 0.824, blue: 1.000)   // #64D2FF
    static let netDown   = Color(red: 0.392, green: 0.824, blue: 1.000)   // #64D2FF
    static let netUp     = Color(red: 0.749, green: 0.353, blue: 0.949)   // #BF5AF2
    static let caution   = Color(red: 1.000, green: 0.839, blue: 0.039)   // #FFD60A

    static let primary   = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.52)
    static let tertiary  = Color.white.opacity(0.32)
    static let card      = Color.white.opacity(0.06)
    static let hairline  = Color.white.opacity(0.08)

    static func color(for state: AgentState) -> Color {
        switch state {
        case .running:    return running
        case .needsInput: return attention
        case .failed:     return failed
        case .completed:  return completed
        case .idle:       return idle
        }
    }

    /// 0...1 pressure → green / yellow / red.
    static func pressure(_ p: Double) -> Color {
        switch p {
        case ..<0.6:  return running
        case ..<0.85: return caution
        default:      return failed
        }
    }

    static func thermal(_ level: ThermalLevel, temp: Double?) -> Color {
        switch level {
        case .critical: return failed
        case .serious:  return attention
        case .fair:     return caution
        case .nominal:
            if let t = temp, t > 90 { return failed }
            if let t = temp, t > 80 { return attention }
            return primary
        }
    }

    static func isWarm(_ level: ThermalLevel, temp: Double?) -> Bool {
        level != .nominal || (temp ?? 0) > 80
    }
}

// MARK: - Typography

extension Font {
    /// SF Pro Rounded — used for numbers, labels and headers.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Motion

enum Motion {
    static let notchSpring = Animation.spring(response: 0.38, dampingFraction: 0.8)
    /// Used instead of the spring when Reduce Motion is on: a short, non-bouncy ease.
    static let reduced = Animation.easeInOut(duration: 0.18)
    static let numbers = Animation.smooth(duration: 0.28)
}

// MARK: - Formatting

enum Fmt {
    static func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    static func gigabytes(_ bytes: UInt64, decimals: Int = 1) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.\(decimals)f", gb)
    }

    /// Compact rate: "0 KB/s", "312 KB/s", "1.4 MB/s", "12 MB/s".
    static func rate(_ bytesPerSec: Double) -> String {
        let kb = max(0, bytesPerSec) / 1024
        if kb < 1000 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1024
        if mb < 10 { return String(format: "%.1f MB/s", mb) }
        if mb < 1000 { return "\(Int(mb.rounded())) MB/s" }
        return String(format: "%.1f GB/s", mb / 1024)
    }

    static func temperature(_ c: Double) -> String { "\(Int(c.rounded()))°" }

    static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "now", "2m", "3h", "4d".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60:     return "now"
        case ..<3600:   return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        default:        return "\(Int(s / 86_400))d"
        }
    }

    /// Elapsed run time: "45s", "4m", "1h 12m".
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return duration(minutes: s / 60)
    }

    static func thermalName(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        }
    }

    /// "claude-opus-5-5" → "Opus 5.5", "gpt-5.2-codex" → "GPT-5.2 Codex"; falls back to provider.
    static func modelChip(provider: String, model: String?) -> String {
        if let model, !model.isEmpty {
            var m = model.lowercased()
            if m.hasPrefix("claude-") {
                m.removeFirst("claude-".count)
                // opus-5-5 → Opus 5.5 ; sonnet-4-5-20250929 → Sonnet 4.5
                let parts = m.split(separator: "-").map(String.init)
                guard let family = parts.first else { return model }
                let nums = parts.dropFirst().filter { $0.count <= 2 && Int($0) != nil }
                let version = nums.prefix(2).joined(separator: ".")
                return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
            }
            if m.hasPrefix("gpt-") {
                let rest = m.dropFirst(4)
                let parts = rest.split(separator: "-").map(String.init)
                let head = "GPT-" + (parts.first ?? "")
                let tail = parts.dropFirst().map { $0.capitalized }.joined(separator: " ")
                return tail.isEmpty ? head : "\(head) \(tail)"
            }
            return model
        }
        switch provider.lowercased() {
        case "claudeagent", "claude", "claudecode": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        default: return provider.isEmpty ? "Agent" : provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }
}

// MARK: - Toolchain workaround

/// The macOS 27 SDK declares `@State` as a macro whose plugin (SwiftUIMacros) ships only with
/// Xcode, so `@State` fails to compile with Command Line Tools. A typealias to the property
/// wrapper struct bypasses the macro and behaves exactly like classic `@State`.
typealias ViewState<Value> = SwiftUI.State<Value>
