import SwiftUI

struct PipelineRowView: View {
    let status: PipelineStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.state.symbolName)
                .foregroundStyle(status.state.color)
                .font(.title3)
                .frame(width: 26)
                .symbolEffect(.pulse, isActive: status.state == .running)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.pipelineName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(status.detail)
                    if let branch = status.branch {
                        Text("· \(branch)").lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let when = status.when {
                Text(relativeFormatter.localizedString(for: when, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
