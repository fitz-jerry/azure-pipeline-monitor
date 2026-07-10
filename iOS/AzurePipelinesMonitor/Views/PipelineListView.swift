import SwiftUI

struct PipelineListView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var viewModel: PipelinesViewModel
    @Environment(\.openURL) private var openURL

    @State private var showSettings = false
    @State private var activeSheet: PipelineActionSheet?

    var body: some View {
        NavigationStack {
            Group {
                if !config.isConfigured {
                    setupPrompt
                } else {
                    pipelineList
                }
            }
            .navigationTitle("Pipelines")
            // Inline avoids the large-title layout breaking under the pinned
            // summary bar (large title would slide up behind the status bar).
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.isRefreshing { ProgressView() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing || !config.isConfigured)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .onDisappear {
                        PhoneConnectivity.shared.sync()
                        Task { await viewModel.refresh() }
                    }
            }
            .pipelineActionSheet($activeSheet, viewModel: viewModel)
        }
        .task {
            if config.isConfigured && viewModel.statuses.isEmpty {
                await viewModel.refresh()
            }
        }
    }

    // MARK: - Pipeline list

    private var pipelineList: some View {
        List {
            if let problem = viewModel.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            ForEach(viewModel.groupedByProject, id: \.project) { group in
                Section(group.project) {
                    ForEach(group.pipelines) { status in
                        row(for: status)
                    }
                }
            }

            if let updated = viewModel.lastUpdated {
                Section {
                    Text("Updated \(relativeFormatter.localizedString(for: updated, relativeTo: Date()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SummaryBar(failing: viewModel.failingCount,
                       awaiting: viewModel.waitingCount,
                       running: viewModel.runningCount,
                       passing: viewModel.succeededCount)
        }
        .refreshable { await viewModel.refresh() }
        .overlay(alignment: .bottom) { actionBanner }
    }

    private func row(for status: PipelineStatus) -> some View {
        NavigationLink {
            PipelineDetailView(initialStatus: status)
        } label: {
            PipelineRowView(status: status)
        }
        .swipeActions(edge: .trailing) {
            Button {
                activeSheet = .run(status.runRef)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            if status.state == .waitingApproval, let ref = status.approvalRef {
                Button {
                    activeSheet = .decide(ref, true)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .tint(.green)
                Button {
                    activeSheet = .decide(ref, false)
                } label: {
                    Label("Reject", systemImage: "xmark")
                }
                .tint(.red)
            }
        }
        .contextMenu {
            if let url = status.webURL {
                Button {
                    openURL(url)
                } label: {
                    Label("Open in Azure DevOps", systemImage: "safari")
                }
            }
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
        }
    }

    @ViewBuilder
    private var actionBanner: some View {
        if let banner = viewModel.actionBanner {
            Text(banner)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { viewModel.actionBanner = nil }
                }
        }
    }

    // MARK: - Setup prompt

    private var setupPrompt: some View {
        ContentUnavailableView {
            Label("Set Up Monitoring", systemImage: "gearshape.2")
        } description: {
            Text("Add your Azure DevOps organization, one or more projects, and a Personal Access Token to start monitoring pipelines.")
        } actions: {
            Button("Open Settings") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
