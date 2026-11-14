import SwiftUI

/// Left side of the header band: "Agents" + live counters.
struct AgentsHeader: View {
    let agents: AgentsSnapshot

    var body: some View {
        // Falls back to number-only chips when space is short (e.g. double-digit counts).
        ViewThatFits(in: .horizontal) {
            content(compact: false)
            content(compact: true)
        }
        .animation(Motion.numbers, value: agents.runningCount)
        .animation(Motion.numbers, value: agents.needsInputCount)
    }

    private func content(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Agents")
                .font(.rounded(13, .bold))
                .foregroundStyle(Palette.primary)
                .fixedSize()
            if agents.runningCount > 0 {
                CountChip(count: agents.runningCount, label: compact ? nil : "running", color: Palette.running)
            }
            if agents.needsInputCount > 0 {
                CountChip(count: agents.needsInputCount, label: compact ? nil : "waiting", color: Palette.attention)
            }
        }
    }
}

private struct CountChip: View {
    let count: Int
    let label: String?
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            if label == nil {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text("\(count)")
                .contentTransition(.numericText(value: Double(count)))
            if let label { Text(label) }
        }
        .font(.rounded(10.5, .semibold))
        .monospacedDigit()
        .foregroundStyle(color)
        .fixedSize()
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Header button that opens T3 Code; its dot doubles as the server-status light.
struct T3HeaderButton: View {
    let online: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StatusOrb(style: online ? .running : .offline, diameter: 5)
                Text(online ? "T3 Code" : "T3 offline")
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .opacity(hovering ? 0.9 : 0.5)
            }
            .font(.rounded(11, .semibold))
            .foregroundStyle(hovering ? Palette.primary : Palette.secondary)
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.1 : 0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Scrollable list of agent threads (or an empty state).
struct AgentsColumn: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        let threads = model.visibleThreads
        if threads.isEmpty {
            AgentsEmptyState(online: model.agents.serverOnline, error: model.agents.lastError)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                // Re-evaluate relative times periodically while visible.
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    VStack(spacing: 2) {
                        ForEach(threads) { thread in
                            AgentRow(thread: thread, now: context.date) {
                                model.openThread(thread.id)
                            }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask(
                // Soft fade at the bottom edge hints there's more to scroll.
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: threads.count > 4 ? 14 : 0)
                }
            )
        }
    }
}

private struct AgentsEmptyState: View {
    let online: Bool
    let error: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: online ? "moon.zzz" : "bolt.slash")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Palette.tertiary)
            Text("No agents running")
                .font(.rounded(13, .semibold))
                .foregroundStyle(Palette.secondary)
            if !online {
                HStack(spacing: 6) {
                    StatusOrb(style: .offline, diameter: 6)
                    Text(error ?? "T3 Code server is offline")
                        .lineLimit(1)
                }
                .font(.rounded(11, .medium))
                .foregroundStyle(Palette.tertiary)
            } else {
                Text("Agents you start in T3 Code show up here.")
                    .font(.rounded(11, .medium))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.035)))
    }
}

// MARK: - Row

struct AgentRow: View {
    let thread: AgentThread
    let now: Date
    let action: () -> Void
    @ViewState private var hovering = false

    private var needsInput: Bool { thread.state == .needsInput }

    private var timeText: String {
        if thread.state == .running, let start = thread.runStartedAt {
            return Fmt.elapsed(since: start, now: now)
        }
        return Fmt.relative(thread.updatedAt, now: now)
    }

    private var secondaryLine: String {
        let preview = thread.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (thread.projectName, preview.isEmpty) {
        case let (p?, false): return "\(p) · \(preview)"
        case let (p?, true):  return p
        case (nil, false):    return preview
        case (nil, true):     return stateLabel
        }
    }

    private var stateLabel: String {
        switch thread.state {
        case .running: return "Working…"
        case .needsInput: return "Waiting for you"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .idle: return "Idle"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                leadingIcon
                    .frame(width: 12, height: 15)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(thread.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(thread.state == .completed || thread.state == .idle
                                             ? Palette.primary.opacity(0.78) : Palette.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(timeText)
                            .font(.rounded(10.5, .medium))
                            .monospacedDigit()
                            .foregroundStyle(thread.state == .running ? Palette.running.opacity(0.85) : Palette.tertiary)
                            .fixedSize()
                    }

                    if needsInput, let summary = thread.pendingRequestSummary, !summary.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(summary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.attention)
                    }

                    HStack(spacing: 5) {
                        Text(secondaryLine)
                            .font(.system(size: 11))
                            .foregroundStyle(thread.state == .failed ? Palette.failed.opacity(0.8) : Palette.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 2)
                        if thread.subagentCount > 0 {
                            SubagentBadge(count: thread.subagentCount)
                        }
                        ModelChip(text: Fmt.modelChip(provider: thread.provider, model: thread.model))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(RowPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("\(thread.title), \(stateLabel)")
    }

    @ViewBuilder private var leadingIcon: some View {
        switch thread.state {
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Palette.completed)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Palette.failed)
        default:
            StatusOrb(style: StatusOrb.style(for: thread.state), diameter: 7)
        }
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        if needsInput {
            shape.fill(Palette.attention.opacity(hovering ? 0.17 : 0.11))
                .overlay(shape.strokeBorder(Palette.attention.opacity(0.22), lineWidth: 0.5))
        } else {
            shape.fill(Color.white.opacity(hovering ? 0.07 : 0))
        }
    }
}

private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct ModelChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.rounded(9.5, .semibold))
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

private struct SubagentBadge: View {
    let count: Int
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8, weight: .bold))
            Text("\(count)")
                .font(.rounded(9.5, .bold))
                .monospacedDigit()
        }
        .foregroundStyle(Palette.running.opacity(0.9))
        .fixedSize()
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Capsule().fill(Palette.running.opacity(0.12)))
        .help("\(count) running subagent\(count == 1 ? "" : "s")")
    }
}
