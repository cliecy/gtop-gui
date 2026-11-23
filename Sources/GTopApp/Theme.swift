import AppKit
import GTopCore
import SwiftUI

enum SidebarDestination: Hashable {
    case overview
    case idleGPUs
    case slurmJobs
    case allProcesses
    case group(String)
    case host(String)
}

struct SlurmLiveProbeTarget: Identifiable, Hashable {
    let id = UUID()
    let loginAlias: String
    let nodeName: String
    let jobID: String?
    let subtitle: String
}

enum GTopTheme {
    static func utilizationColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        switch value {
        case ..<35: return Color(nsColor: .systemGreen)
        case 35..<75: return Color(nsColor: .systemBlue)
        case 75..<92: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }

    static func memoryColor(_ percent: Double) -> Color {
        switch percent {
        case ..<45: return Color(nsColor: .systemTeal)
        case 45..<80: return Color(nsColor: .systemIndigo)
        case 80..<93: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }

    static func temperatureColor(_ celsius: Double?) -> Color {
        guard let celsius else { return .secondary }
        switch celsius {
        case ..<55: return Color(nsColor: .systemGreen)
        case 55..<75: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }

    static func statusColor(_ status: HostConnectionStatus) -> Color {
        switch status {
        case .online: return Color(nsColor: .systemGreen)
        case .connecting: return Color(nsColor: .systemOrange)
        case .noGPU: return Color(nsColor: .systemYellow)
        case .error: return Color(nsColor: .systemRed)
        case .idle, .paused: return Color(nsColor: .systemGray)
        }
    }

    static func slurmNodeColor(_ category: SlurmNodeStateCategory) -> Color {
        switch category {
        case .idle: return Color(nsColor: .systemGreen)
        case .mixed: return Color(nsColor: .systemBlue)
        case .allocated: return Color(nsColor: .systemOrange)
        case .draining, .down: return Color(nsColor: .systemRed)
        case .other: return Color(nsColor: .systemGray)
        }
    }

    static func slurmJobColor(_ state: SlurmJobState) -> Color {
        switch state {
        case .running: return Color(nsColor: .systemGreen)
        case .pending: return Color(nsColor: .systemOrange)
        case .completing: return Color(nsColor: .systemBlue)
        case .other: return Color(nsColor: .systemGray)
        }
    }

    static let gpuSeriesPalette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red,
        .mint, .cyan, .yellow, .brown
    ]

    static func gpuColor(index: Int) -> Color {
        gpuSeriesPalette[abs(index) % gpuSeriesPalette.count]
    }
}

enum SystemActions {
    @MainActor
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    static func openSSHInTerminal(alias: String) {
        // Use macOS ssh:// URL handler (opens Terminal.app / user's registered SSH handler cleanly)
        let encoded = alias.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? alias
        if let url = URL(string: "ssh://\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}
