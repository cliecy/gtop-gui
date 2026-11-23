import Charts
import GTopCore
import SwiftUI

enum ChartMetricKind: String, CaseIterable, Identifiable {
    case allGrid = "综合四图"
    case gpuUtil = "算力利用率"
    case memory = "显存占用"
    case temperature = "温度"
    case power = "功耗"
    case fan = "风扇转速"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .allGrid: return ""
        case .gpuUtil, .memory, .fan: return "%"
        case .temperature: return "°C"
        case .power: return "W"
        }
    }
}

struct MiniSparkline: View {
    let samples: [GPUSamplePoint]
    let tint: Color

    var body: some View {
        if samples.count >= 2 {
            Chart(samples) { point in
                AreaMark(
                    x: .value("时间", point.timestamp),
                    y: .value("利用率", point.gpuUtilization)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("时间", point.timestamp),
                    y: .value("利用率", point.gpuUtilization)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(tint)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...100)
            .chartLegend(.hidden)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    Text("采集中…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                )
        }
    }
}

struct GPUDetailChartsPanel: View {
    let host: HostMonitorState
    let selectedGPUID: String? // nil means overlay all GPUs on the host
    @State private var selectedMetric: ChartMetricKind = .allGrid

    private var targetGPUs: [GPUMetric] {
        if let id = selectedGPUID, let found = host.gpus.first(where: { $0.id == id }) {
            return [found]
        }
        return host.gpus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    selectedGPUID == nil ? "实时趋势（全部 \(host.gpus.count) 卡对比）" : "实时趋势（GPU \(targetGPUs.first?.index ?? 0)）",
                    systemImage: "chart.xyaxis.line"
                )
                .font(.headline)

                Spacer()

                Picker("指标", selection: $selectedMetric) {
                    ForEach(ChartMetricKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
            }

            if selectedMetric == .allGrid {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    SingleMetricChartCard(
                        title: "GPU 算力利用率",
                        unit: "%",
                        yDomain: 0...100,
                        gpus: targetGPUs,
                        historyByGPU: host.historyByGPU,
                        valueProvider: { $0.gpuUtilization },
                        singleColor: .blue
                    )
                    SingleMetricChartCard(
                        title: "显存占用率",
                        unit: "%",
                        yDomain: 0...100,
                        gpus: targetGPUs,
                        historyByGPU: host.historyByGPU,
                        valueProvider: { $0.memoryPercent },
                        singleColor: .indigo
                    )
                    SingleMetricChartCard(
                        title: "核心温度",
                        unit: "°C",
                        yDomain: 20...100,
                        gpus: targetGPUs,
                        historyByGPU: host.historyByGPU,
                        valueProvider: { $0.temperatureC },
                        singleColor: .orange
                    )
                    SingleMetricChartCard(
                        title: "实时功耗",
                        unit: "W",
                        yDomain: nil,
                        gpus: targetGPUs,
                        historyByGPU: host.historyByGPU,
                        valueProvider: { $0.powerDrawW },
                        singleColor: .green
                    )
                }
            } else {
                SingleMetricChartCard(
                    title: selectedMetric.rawValue,
                    unit: selectedMetric.unit,
                    yDomain: yDomain(for: selectedMetric),
                    gpus: targetGPUs,
                    historyByGPU: host.historyByGPU,
                    valueProvider: valueExtractor(for: selectedMetric),
                    singleColor: singleColor(for: selectedMetric),
                    chartHeight: 240
                )
            }
        }
    }

    private func yDomain(for kind: ChartMetricKind) -> ClosedRange<Double>? {
        switch kind {
        case .gpuUtil, .memory, .fan: return 0...100
        case .temperature: return 20...100
        case .power, .allGrid: return nil
        }
    }

    private func singleColor(for kind: ChartMetricKind) -> Color {
        switch kind {
        case .gpuUtil: return .blue
        case .memory: return .indigo
        case .temperature: return .orange
        case .power: return .green
        case .fan: return .teal
        case .allGrid: return .blue
        }
    }

    private func valueExtractor(for kind: ChartMetricKind) -> (GPUSamplePoint) -> Double? {
        switch kind {
        case .gpuUtil, .allGrid: return { $0.gpuUtilization }
        case .memory: return { $0.memoryPercent }
        case .temperature: return { $0.temperatureC }
        case .power: return { $0.powerDrawW }
        case .fan: return { $0.fanSpeedPercent }
        }
    }
}

private struct SingleMetricChartCard: View {
    let title: String
    let unit: String
    let yDomain: ClosedRange<Double>?
    let gpus: [GPUMetric]
    let historyByGPU: [String: [GPUSamplePoint]]
    let valueProvider: (GPUSamplePoint) -> Double?
    let singleColor: Color
    var chartHeight: CGFloat = 155

    private struct FlatPoint: Identifiable {
        let id: String
        let gpuLabel: String
        let gpuIndex: Int
        let timestamp: Date
        let value: Double
    }

    private var points: [FlatPoint] {
        var result: [FlatPoint] = []
        for gpu in gpus {
            let series = historyByGPU[gpu.id] ?? []
            let label = "GPU \(gpu.index)"
            for sample in series {
                if let val = valueProvider(sample) {
                    result.append(FlatPoint(
                        id: "\(gpu.id)-\(sample.id.uuidString)",
                        gpuLabel: label,
                        gpuIndex: gpu.index,
                        timestamp: sample.timestamp,
                        value: val
                    ))
                }
            }
        }
        return result
    }

    private var latestSummary: String {
        if gpus.count == 1, let gpu = gpus.first,
           let last = historyByGPU[gpu.id]?.last,
           let val = valueProvider(last)
        {
            return String(format: "%.0f%@", val, unit)
        }
        let latestValues = gpus.compactMap { gpu -> Double? in
            guard let last = historyByGPU[gpu.id]?.last else { return nil }
            return valueProvider(last)
        }
        guard !latestValues.isEmpty else { return "—" }
        let avg = latestValues.reduce(0, +) / Double(latestValues.count)
        return String(format: "均 %.0f%@", avg, unit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(latestSummary)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(gpus.count == 1 ? singleColor : .primary)
            }

            if points.isEmpty {
                ContentUnavailableView {
                    Text("暂无采样数据")
                        .font(.caption)
                } description: {
                    Text("等待下一轮采集或该传感器不支持")
                        .font(.caption2)
                }
                .frame(height: chartHeight)
            } else if gpus.count == 1 {
                singleSeriesChart
                    .frame(height: chartHeight)
            } else {
                multiSeriesChart
                    .frame(height: chartHeight)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var singleSeriesChart: some View {
        let base = Chart(points) { pt in
            AreaMark(
                x: .value("时间", pt.timestamp),
                y: .value(title, pt.value)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(
                LinearGradient(
                    colors: [singleColor.opacity(0.28), singleColor.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LineMark(
                x: .value("时间", pt.timestamp),
                y: .value(title, pt.value)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .foregroundStyle(singleColor)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour().minute().second())
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let num = value.as(Double.self) {
                        Text("\(Int(num))\(unit)")
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }

        if let yDomain {
            base.chartYScale(domain: yDomain)
        } else {
            base
        }
    }

    @ViewBuilder
    private var multiSeriesChart: some View {
        let labels = gpus.map { "GPU \($0.index)" }
        let colors = gpus.map { GTopTheme.gpuColor(index: $0.index) }

        let base = Chart(points) { pt in
            LineMark(
                x: .value("时间", pt.timestamp),
                y: .value(title, pt.value)
            )
            .foregroundStyle(by: .value("GPU", pt.gpuLabel))
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 1.8))
        }
        .chartForegroundStyleScale(domain: labels, range: colors)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour().minute().second())
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let num = value.as(Double.self) {
                        Text("\(Int(num))\(unit)")
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }

        if let yDomain {
            base.chartYScale(domain: yDomain)
        } else {
            base
        }
    }
}
