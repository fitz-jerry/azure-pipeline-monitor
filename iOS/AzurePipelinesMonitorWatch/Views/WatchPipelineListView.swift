import SwiftUI

struct WatchPipelineListView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var viewModel: WatchPipelinesViewModel

    private var grouped: [(project: String, pipelines: [PipelineStatus])] {
        Dictionary(grouping: viewModel.statuses, by: \.project)
            .map { (project: $0.key, pipelines: $0.value) }
            .sorted { $0.project.lowercased() < $1.project.lowercased() }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.statuses.isEmpty {
                    list
                } else if viewModel.isConfigured {
                    ProgressView().controlSize(.large)
                } else {
                    notConfigured
                }
            }
            .navigationTitle("Pipelines")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing || !viewModel.isConfigured)
                }
            }
        }
        .task {
            WatchConnectivityReceiver.shared.onUpdate = {
                Task { await viewModel.refresh() }
            }
            if viewModel.isConfigured && viewModel.statuses.isEmpty {
                await viewModel.refresh()
            }
        }
    }

    private var list: some View {
        List {
            WatchSummaryRow(failing: viewModel.failingCount,
                            awaiting: viewModel.waitingCount,
                            running: viewModel.runningCount,
                            passing: viewModel.succeededCount)

            ForEach(grouped, id: \.project) { group in
                Section(group.project) {
                    ForEach(group.pipelines) { status in
                        NavigationLink {
                            WatchPipelineDetailView(initialStatus: status)
                        } label: {
                            WatchPipelineRow(status: status)
                        }
                    }
                }
            }

            if let problem = viewModel.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                }
            }
        }
        .refreshable { await viewModel.refresh() }
    }

    private var notConfigured: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Azure Pipelines on your iPhone to sync your account.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct WatchPipelineRow: View {
    let status: PipelineStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.state.symbolName)
                .foregroundStyle(status.state.color)
                .symbolEffect(.pulse, isActive: status.state == .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.pipelineName)
                    .font(.caption)
                    .lineLimit(1)
                Text(status.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct WatchSummaryRow: View {
    let failing: Int
    let awaiting: Int
    let running: Int
    let passing: Int

    var body: some View {
        HStack(spacing: 10) {
            badge(failing, PipelineState.failed)
            badge(awaiting, PipelineState.waitingApproval)
            badge(running, PipelineState.running)
            badge(passing, PipelineState.succeeded)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func badge(_ count: Int, _ state: PipelineState) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Image(systemName: state.symbolName)
                    .foregroundStyle(state.color)
                Text("\(count)")
                    .fontWeight(.semibold)
            }
            .font(.caption2)
        }
    }
}
