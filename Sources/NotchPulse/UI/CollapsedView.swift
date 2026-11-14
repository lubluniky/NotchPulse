import SwiftUI

/// Collapsed island: two "wings" flanking the hardware notch.
struct CollapsedView: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        let g = model.geometry
        HStack(spacing: 0) {
            AgentsWing(agents: model.agents)
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(width: g.wingWidth, alignment: .leading)
            Color.clear.frame(width: g.centerGap)
            SystemWing(system: model.system)
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .frame(width: g.wingWidth, alignment: .trailing)
        }
        .padding(.horizontal, g.collapsedEar)
        .frame(height: g.bandHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.isExpanded = true }
    }
}

// MARK: - Left wing: agent status

private struct AgentsWing: View {
    let agents: AgentsSnapshot

    var body: some View {
        HStack(spacing: 7) {
            if agents.needsInputCount > 0 {
                HStack(spacing: 5) {
                    StatusOrb(style: .attention, diameter: 7)
                    Text("\(agents.needsInputCount)")
                        .fixedSize()
                        .contentTransition(.numericText(value: Double(agents.needsInputCount)))
                }
                .foregroundStyle(Palette.attention)
                .padding(.leading, 6)
                .padding(.trailing, 7)
                .frame(height: 19)
                .background(Capsule().fill(Palette.attention.opacity(0.18)))
                .overlay(Capsule().strokeBorder(Palette.attention.opacity(0.28), lineWidth: 0.5))
            }
            if agents.runningCount > 0 {
                HStack(spacing: 5) {
                    StatusOrb(style: .running, diameter: 7)
                    Text("\(agents.runningCount)")
                        .fixedSize()
                        .foregroundStyle(Palette.primary)
                        .contentTransition(.numericText(value: Double(agents.runningCount)))
                }
            }
            if agents.needsInputCount == 0 && agents.runningCount == 0 {
                HStack(spacing: 6) {
                    StatusOrb(style: agents.serverOnline ? .idle : .offline, diameter: 7)
                    Text(agents.serverOnline ? "idle" : "off")
                        .fixedSize()
                        .foregroundStyle(Palette.tertiary)
                }
            }
        }
        .font(.rounded(12, .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .animation(Motion.numbers, value: agents.needsInputCount)
        .animation(Motion.numbers, value: agents.runningCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agents.runningCount) agents running, \(agents.needsInputCount) waiting for input")
    }
}

// MARK: - Right wing: system glance

private struct SystemWing: View {
    let system: SystemSnapshot

    private var lowBattery: Bool {
        guard let level = system.batteryLevel else { return false }
        return level <= 0.2 && !system.isPluggedIn
    }

    var body: some View {
        HStack(spacing: 7) {
            Sparkline(values: Array(system.cpuHistory.suffix(20)), color: Palette.cpu,
                      lineWidth: 1.25, showArea: true)
                .frame(width: 24, height: 12)

            if lowBattery, let level = system.batteryLevel {
                HStack(spacing: 3) {
                    Image(systemName: "battery.25percent")
                        .font(.system(size: 11, weight: .semibold))
                    Text(Fmt.percent(level))
                        .fixedSize()
                        .contentTransition(.numericText(value: level))
                }
                .foregroundStyle(Palette.failed)
            } else if let t = system.socTemperature {
                Text(Fmt.temperature(t))
                    .fixedSize()
                    .foregroundStyle(Palette.isWarm(system.thermalState, temp: t)
                                     ? Palette.thermal(system.thermalState, temp: t) : Palette.primary)
            } else {
                Text(Fmt.percent(system.cpuUsage))
                    .fixedSize()
                    .foregroundStyle(Palette.primary)
            }
        }
        .font(.rounded(12, .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(Fmt.percent(system.cpuUsage))")
    }
}
