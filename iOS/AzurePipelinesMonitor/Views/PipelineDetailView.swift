import SwiftUI

struct PipelineDetailView: View {
    /// Snapshot captured at navigation time; used as a fallback if the pipeline
    /// drops out of the next refresh (the live copy is preferred while present).
    let initialStatus: PipelineStatus

    @EnvironmentObject var viewModel: PipelinesViewModel
    @Environment(\.openURL) private var openURL
    @State private var activeSheet: PipelineActionSheet?

    private var status: PipelineStatus {
        viewModel.status(forKey: initialStatus.key) ?? initialStatus
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: status.state.symbolName)
                        .font(.system(size: 40))
                        .foregroundStyle(status.state.color)
                        .symbolEffect(.pulse, isActive: status.state == .running)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.state.displayName)
                            .font(.title2.bold())
                        Text(status.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section("Details") {
                detailRow("Pipeline", status.pipelineName)
                detailRow("Project", status.project)
                detailRow("Build", "#\(status.buildNumber)")
                if let branch = status.branch {
                    detailRow("Branch", branch)
                }
                if let when = status.when {
                    detailRow("Last run", when.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                Button {
                    activeSheet = .run(status.runRef)
                } label: {
                    Label("Run Pipeline…", systemImage: "play.fill")
                }

                if status.state == .waitingApproval, let ref = status.approvalRef {
                    Button {
                        activeSheet = .decide(ref, true)
                    } label: {
                        Label("Approve…", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        activeSheet = .decide(ref, false)
                    } label: {
                        Label("Reject…", systemImage: "xmark.circle")
                    }
                }

                if let url = status.webURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open in Azure DevOps", systemImage: "safari")
                    }
                }
            }
        }
        .navigationTitle(status.pipelineName)
        .navigationBarTitleDisplayMode(.inline)
        .pipelineActionSheet($activeSheet, viewModel: viewModel)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
