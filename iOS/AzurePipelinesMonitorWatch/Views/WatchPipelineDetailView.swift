import SwiftUI

struct WatchPipelineDetailView: View {
    let initialStatus: PipelineStatus
    @EnvironmentObject var viewModel: WatchPipelinesViewModel

    private var status: PipelineStatus {
        viewModel.status(forKey: initialStatus.key) ?? initialStatus
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: status.state.symbolName)
                        .font(.title3)
                        .foregroundStyle(status.state.color)
                        .symbolEffect(.pulse, isActive: status.state == .running)
                    Text(status.state.displayName)
                        .font(.headline)
                }

                VStack(alignment: .leading, spacing: 4) {
                    detail("Project", status.project)
                    detail("Build", "#\(status.buildNumber)")
                    if let branch = status.branch { detail("Branch", branch) }
                }
                .font(.caption2)

                if status.state == .waitingApproval, let ref = status.approvalRef {
                    NavigationLink {
                        WatchApprovalView(ref: ref, approve: true)
                    } label: {
                        Label("Approve", systemImage: "checkmark.circle")
                    }
                    .tint(.green)

                    NavigationLink {
                        WatchApprovalView(ref: ref, approve: false)
                    } label: {
                        Label("Reject", systemImage: "xmark.circle")
                    }
                    .tint(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle(status.pipelineName)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
