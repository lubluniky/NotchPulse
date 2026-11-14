import SwiftUI

/// Right column: system tiles. CPU spans the top; four half tiles below.
struct SystemColumn: View {
    let system: SystemSnapshot
    var spacing: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let small = ((geo.size.height - 2 * spacing) * 0.31).rounded()
            let large = geo.size.height - 2 * spacing - 2 * small
            VStack(spacing: spacing) {
                CPUTile(system: system).frame(height: large)
                HStack(spacing: spacing) {
                    MemoryTile(system: system)
                    TempTile(system: system)
                }
                .frame(height: small)
                HStack(spacing: spacing) {
                    BatteryTile(system: system)
                    NetworkTile(system: system)
                }
                .frame(height: small)
            }
        }
    }
}

// MARK: - Tile chrome

private struct Tile<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .font(.rounded(9, .bold))
                    .kerning(0.6)
                    .foregroundStyle(Palette.tertiary)
                Spacer(minLength: 0)
                accessory
            }
            .frame(height: 11)
            Spacer(minLength: 2)
            content
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
    }
}

private struct BigValue: View {
    let text: String
    let value: Double
    var size: CGFloat = 16
    var color: Color = Palette.primary
    /// Rolling-digit transition. Only for values that change rarely: `numericText` is
    /// CPU-rasterized with blur on macOS and costs ~20% CPU when re-fired every second.
    var animated: Bool = false

    var body: some View {
        Text(text)
            .font(.rounded(size, .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(animated ? .numericText(value: value) : .identity)
            .animation(animated ? Motion.numbers : nil, value: value)
            .lineLimit(1)
    }
}

// MARK: - CPU

private struct CPUTile: View {
    let system: SystemSnapshot

    var body: some View {
        Tile("CPU") {
            EmptyView()
        } content: {
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                    BigValue(text: "\(Int((system.cpuUsage * 100).rounded()))", value: system.cpuUsage.rounded(to: 0.01), size: 24)
                    Text("%")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                .frame(minWidth: 52, alignment: .leading)

                Sparkline(values: Array(system.cpuHistory.suffix(40)), color: Palette.cpu,
                          lineWidth: 1.5, showArea: true, showHead: true)
                    .padding(.trailing, 3)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Memory

private struct MemoryTile: View {
    let system: SystemSnapshot

    private var fraction: Double {
        guard system.memoryTotal > 0 else { return 0 }
        return min(1, Double(system.memoryUsed) / Double(system.memoryTotal))
    }

    var body: some View {
        let color = Palette.pressure(system.memoryPressure)
        Tile("Memory") {
            Circle().fill(color).frame(width: 5, height: 5)
                .help("Memory pressure \(Fmt.percent(system.memoryPressure))")
        } content: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    BigValue(text: Fmt.gigabytes(system.memoryUsed), value: Double(system.memoryUsed) / 1e8)
                    Text("/ \(Fmt.gigabytes(system.memoryTotal, decimals: 0)) GB")
                        .font(.rounded(10, .semibold))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                }
                MeterBar(fraction: fraction, color: color)
            }
        }
    }
}

private struct MeterBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
        .animation(Motion.numbers, value: (fraction * 100).rounded())
    }
}

// MARK: - Temperature

private struct TempTile: View {
    let system: SystemSnapshot

    var body: some View {
        let warm = Palette.isWarm(system.thermalState, temp: system.socTemperature)
        let color = Palette.thermal(system.thermalState, temp: system.socTemperature)
        Tile("Temp") {
            Image(systemName: warm ? "thermometer.high" : "thermometer.medium")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(warm ? color : Palette.tertiary)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if let t = system.socTemperature {
                    HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                        BigValue(text: "\(Int(t.rounded()))", value: t.rounded(), color: warm ? color : Palette.primary)
                        Text("°C")
                            .font(.rounded(10, .semibold))
                            .foregroundStyle(warm ? color.opacity(0.7) : Palette.tertiary)
                    }
                } else {
                    BigValue(text: Fmt.thermalName(system.thermalState), value: 0, size: 14, color: color)
                }
                Text(system.socTemperature == nil ? "Thermal state" : Fmt.thermalName(system.thermalState))
                    .font(.rounded(10, .semibold))
                    .foregroundStyle(warm ? color.opacity(0.85) : Palette.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Battery

private struct BatteryTile: View {
    let system: SystemSnapshot

    private var color: Color {
        guard let level = system.batteryLevel else { return Palette.secondary }
        if system.isCharging { return Palette.running }
        if level <= 0.1 { return Palette.failed }
        if level <= 0.2 { return Palette.attention }
        return Palette.primary
    }

    private var subtitle: String {
        guard let level = system.batteryLevel else { return "AC power" }
        // macOS shows a whole 100% during the final top-off while still reporting a
        // time-to-full estimate; "100% · 14m to full" reads as a bug, so drop the time.
        if Int((level * 100).rounded()) >= 100 {
            return system.isCharging ? "Topping off" : "Charged"
        }
        if let m = system.batteryTimeRemaining, m > 0 {
            return system.isCharging ? "\(Fmt.duration(minutes: m)) to full" : "\(Fmt.duration(minutes: m)) left"
        }
        if system.isCharging { return "Charging" }
        if system.isPluggedIn { return "Plugged in" }
        return "Calculating…"
    }

    var body: some View {
        Tile("Battery") {
            if system.isCharging || system.isPluggedIn {
                Image(systemName: system.isCharging ? "bolt.fill" : "powerplug.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(system.isCharging ? Palette.running : Palette.tertiary)
            }
        } content: {
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    if let level = system.batteryLevel {
                        HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                            BigValue(text: "\(Int((level * 100).rounded()))", value: (level * 100).rounded(), color: color, animated: true)
                            Text("%")
                                .font(.rounded(10, .semibold))
                                .foregroundStyle(Palette.tertiary)
                        }
                    } else {
                        BigValue(text: "—", value: 0)
                    }
                    Text(subtitle)
                        .font(.rounded(10, .semibold))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                if let level = system.batteryLevel {
                    BatteryRing(level: level, color: color == Palette.primary ? Palette.running : color)
                        .frame(width: 20, height: 20)
                        .padding(.bottom, 1)
                }
            }
        }
    }
}

private struct BatteryRing: View {
    let level: Double
    let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, level)))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(Motion.numbers, value: (level * 100).rounded())
    }
}

// MARK: - Network

private struct NetworkTile: View {
    let system: SystemSnapshot

    var body: some View {
        Tile("Network") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 3) {
                RateLine(symbol: "arrow.down", color: Palette.netDown, rate: system.netDownBytesPerSec)
                RateLine(symbol: "arrow.up", color: Palette.netUp, rate: system.netUpBytesPerSec)
            }
        }
    }
}

private struct RateLine: View {
    let symbol: String
    let color: Color
    let rate: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(color)
                .frame(width: 9)
            Text(Fmt.rate(rate))
                .font(.rounded(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(rate < 1024 ? Palette.secondary : Palette.primary)
                .lineLimit(1)
        }
    }
}

private extension Double {
    func rounded(to step: Double) -> Double { (self / step).rounded() * step }
}
