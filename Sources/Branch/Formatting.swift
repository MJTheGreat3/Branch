import BranchCore
import SwiftUI

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func relative(_ date: Date?, placeholder: String = "Never") -> String {
        guard let date else { return placeholder }
        if date == .distantPast { return "Now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

extension BackupStatus {
    var symbol: String {
        switch self {
        case .idle: return "circle.dashed"
        case .queued: return "clock"
        case .uploading: return "arrow.up.circle"
        case .backedUp: return "checkmark.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .queued: return .blue
        case .uploading: return .blue
        case .backedUp: return .green
        case .needsAttention: return .orange
        case .paused: return .secondary
        }
    }
}

struct StatusBadge: View {
    let status: BackupStatus

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .foregroundStyle(status.tint)
    }
}
