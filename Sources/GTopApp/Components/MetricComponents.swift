import GTopCore
import SwiftUI

struct StatusDot: View {
    let status: HostConnectionStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(GTopTheme.statusColor(status))
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(GTopTheme.statusColor(status).opacity(0.35), lineWidth: status.isOnline ? 2 : 0)
            )
    }
}

/// Compact vertical bar equalizer representing each GPU's utilization on a host.
struct MiniGPUHeatBars: View {
    let gpus: [GPUMetric]
    var maxHeight: CGFloat = 14
    var barWidth: CGFloat = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(gpus) { gpu in
                let util = max(gpu.gpuUtilization ?? 0, gpu.memoryPercent * 0.4)
                let normalized = max(0.14, min(1.0, util / 100.0))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(GTopTheme.utilizationColor(gpu.gpuUtilization))
                    .frame(width: barWidth, height: maxHeight * normalized)
            }
        }
        .frame(height: maxHeight, alignment: .bottom)
    }
}

struct MetricProgressBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(tint)
                    .frame(width: max(clamped > 0 ? 3 : 0, geo.size.width * clamped))
            }
        }
        .frame(height: height)
    }
}

struct KPICard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let accent: Color
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let progress {
                MetricProgressBar(fraction: progress, tint: accent, height: 5)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct BadgePill: View {
    let text: String
    var color: Color = .secondary
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct ToastOverlay: View {
    let message: String?

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThickMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
