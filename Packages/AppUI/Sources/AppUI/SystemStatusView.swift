import ScanKit
import SwiftUI

private enum SystemStatusMetric: String, CaseIterable, Identifiable {
    case cpu, memory, disk, battery, network
    var id: String { rawValue }
    var titleKey: String { "workspace.metric.\(rawValue)" }
    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .battery: return "battery.75percent"
        case .network: return "network"
        }
    }
    var tint: Color {
        switch self {
        case .cpu: return SmartCareMotionPalette.blueColor
        case .memory: return SmartCareMotionPalette.amberColor
        case .disk: return .cyan
        case .battery: return .orange
        case .network: return SmartCareMotionPalette.tealColor
        }
    }
}

struct SystemStatusStrip: View {
    @ObservedObject var store: SystemStatusStore
    @ObservedObject var probe: SystemProbeStore
    let onSelect: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ForEach(SystemStatusMetric.allCases) { metric in
                Button(action: onSelect) {
                    SystemStatusMetricCard(
                        metric: metric, samples: store.samples,
                        volume: probe.volumeSnapshot, expanded: false)
                }
                .buttonStyle(.plain)
                .help(Text("workspace.status.open", bundle: .module))
            }
        }
        .accessibilityIdentifier("normal.status.strip")
    }
}

struct SystemStatusDashboard: View {
    @ObservedObject var store: SystemStatusStore
    @ObservedObject var probe: SystemProbeStore
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("workspace.status.title", bundle: .module)
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text("workspace.status.subtitle", bundle: .module)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label {
                        Text("workspace.status.live", bundle: .module)
                    } icon: {
                        Image(systemName: "circle.fill").font(.system(size: 6))
                    }
                    .font(.caption).foregroundStyle(SmartCareMotionPalette.tealColor)
                    .padding(10).background(SmartCareMotionPalette.tealColor.opacity(0.08), in: Capsule())
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16
                ) {
                    ForEach(SystemStatusMetric.allCases) { metric in
                        SystemStatusMetricCard(
                            metric: metric, samples: store.samples,
                            volume: probe.volumeSnapshot, expanded: true)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Label {
                            Text("workspace.status.uptime", bundle: .module)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: uptimeText)
                            .font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                        Spacer(minLength: 0)
                        Text(LocalizedStringKey(thermalKey), bundle: .module)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20).frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
                    .smartCareTechSurface(tint: .indigo, cornerRadius: 16, elevated: false)
                }
                Label {
                    Text("workspace.status.measurement_note", bundle: .module)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
        }
    }

    private var uptimeText: String {
        guard let uptime = store.latest?.uptime else {
            return AppLocalization.string("workspace.metric.waiting", locale: locale)
        }
        let hours = Int64(uptime / 3_600)
        return AppLocalization.format(
            "workspace.status.uptime.value %lld %lld", locale: locale,
            arguments: [hours / 24, hours % 24])
    }

    private var thermalKey: String {
        switch store.latest?.thermalState {
        case 0: return "workspace.status.thermal.nominal"
        case 1: return "workspace.status.thermal.fair"
        case 2: return "workspace.status.thermal.serious"
        case 3: return "workspace.status.thermal.critical"
        default: return "workspace.metric.waiting"
        }
    }
}

private struct SystemStatusMetricCard: View {
    let metric: SystemStatusMetric
    let samples: [SystemStatusSample]
    let volume: VolumeCapacity.Snapshot?
    let expanded: Bool
    @Environment(\.locale) private var locale
    private var latest: SystemStatusSample? { samples.last }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 14 : 8) {
            Label {
                Text(LocalizedStringKey(metric.titleKey), bundle: .module)
            } icon: {
                Image(systemName: metric.icon)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(metric.tint)
            Text(verbatim: value)
                .font(.system(size: expanded ? 32 : 24, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            if metric == .disk {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(metric.tint.opacity(0.1))
                        if let volume {
                            Capsule().fill(metric.tint.opacity(0.65))
                                .frame(width: geometry.size.width * usedFraction(volume))
                        }
                    }.frame(height: 4).frame(maxHeight: .infinity)
                }.frame(height: expanded ? 44 : 23)
            } else {
                SystemMetricSparkline(
                    values: history, times: samples.map(\.uptime), tint: metric.tint,
                    upperBound: metric == .network ? nil : 1
                )
                .frame(height: expanded ? 44 : 23)
            }
            Text(verbatim: detail)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(expanded ? 20 : 14)
        .frame(maxWidth: .infinity, minHeight: expanded ? 190 : 119, alignment: .leading)
        .smartCareTechSurface(tint: metric.tint, cornerRadius: 14, elevated: false)
        .accessibilityElement(children: .combine)
    }

    private var value: String {
        switch metric {
        case .cpu: return percent(latest?.cpu)
        case .memory: return percent(latest?.memory?.fraction)
        case .disk: return percent(volume.map(usedFraction))
        case .battery:
            if latest?.battery == .notPresent { return text("workspace.metric.ac_power") }
            return percent(latest?.battery.fraction)
        case .network:
            guard let rate = latest?.network else { return unknown }
            return rateText(rate.received + rate.sent)
        }
    }

    private var detail: String {
        switch metric {
        case .cpu: return text("workspace.metric.cpu.detail")
        case .memory:
            guard let memory = latest?.memory else { return text("workspace.metric.memory.detail") }
            return "\(bytes(memory.used)) / \(bytes(memory.total))"
        case .disk:
            guard let volume else { return text("workspace.metric.unavailable") }
            return AppLocalization.format(
                "workspace.metric.disk.free %@", locale: locale,
                arguments: [AppLocalization.byteCount(volume.availableBytes, locale: locale)])
        case .battery:
            switch latest?.battery {
            case .battery(_, let charging, let onAC, let minutes):
                if charging { return text("workspace.metric.charging") }
                if onAC { return text("workspace.metric.ac_power") }
                if let minutes {
                    return AppLocalization.format(
                        "workspace.metric.battery.remaining %lld", locale: locale,
                        arguments: [Int64(minutes)])
                }
                return text("workspace.metric.battery.using")
            case .notPresent: return text("workspace.metric.no_battery")
            case .unavailable, nil: return unknown
            }
        case .network:
            guard let rate = latest?.network else { return text("workspace.metric.network.detail") }
            return "↑ \(rateText(rate.sent))  ↓ \(rateText(rate.received))"
        }
    }

    private var history: [Double?] {
        samples.map { sample in
            switch metric {
            case .cpu: return sample.cpu
            case .memory: return sample.memory?.fraction
            case .battery: return sample.battery.fraction
            case .network: return sample.network.map { $0.received + $0.sent }
            case .disk: return nil
            }
        }
    }

    private var unknown: String {
        text(latest == nil ? "workspace.metric.waiting" : "workspace.metric.unavailable")
    }
    private func text(_ key: String) -> String { AppLocalization.string(key, locale: locale) }
    private func bytes(_ value: UInt64) -> String {
        AppLocalization.byteCount(Int64(clamping: value), locale: locale)
    }
    private func percent(_ value: Double?) -> String {
        guard let value else { return unknown }
        return value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
    private func usedFraction(_ volume: VolumeCapacity.Snapshot) -> Double {
        Double(volume.usedBytes) / Double(max(1, volume.totalBytes))
    }
    private func rateText(_ rate: Double) -> String {
        AppLocalization.format(
            "workspace.metric.rate %@", locale: locale,
            arguments: [
                AppLocalization.byteCount(Int64(min(Double(Int64.max - 1024), max(0, rate))), locale: locale)
            ])
    }
}

private struct SystemMetricSparkline: View {
    let values: [Double?]
    let times: [TimeInterval]
    let tint: Color
    let upperBound: Double?

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(upperBound ?? values.compactMap { $0 }.max() ?? 1, 0.001)
            Path { path in
                var connected = false
                for (index, value) in values.enumerated() {
                    guard let value, value.isFinite else {
                        connected = false
                        continue
                    }
                    // The x axis always represents the retained 60-second window. A fresh
                    // sampler draws only the real tail, never a fabricated full history.
                    guard times.indices.contains(index), let latestTime = times.last else { continue }
                    let x = geometry.size.width * max(0, 1 - (latestTime - times[index]) / 60)
                    let y = geometry.size.height * (1 - min(1, max(0, value / maximum)))
                    let point = CGPoint(x: x, y: y)
                    if connected { path.addLine(to: point) } else { path.move(to: point) }
                    connected = true
                }
            }
            .stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .background(alignment: .bottom) { Rectangle().fill(tint.opacity(0.1)).frame(height: 1) }
        }
        .accessibilityHidden(true)
    }
}
