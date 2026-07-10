import Foundation
import SwiftUI

@MainActor
final class PipelinesViewModel: ObservableObject {
    @Published var statuses: [PipelineStatus] = []
    @Published var problem: String?
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false
    /// Transient banner shown after a Run/Approve action.
    @Published var actionBanner: String?

    private let config: AppConfig

    init(config: AppConfig = .shared) {
        self.config = config
    }

    /// Pipelines grouped by project, projects in alphabetical order.
    var groupedByProject: [(project: String, pipelines: [PipelineStatus])] {
        Dictionary(grouping: statuses, by: \.project)
            .map { (project: $0.key, pipelines: $0.value) }
            .sorted { $0.project.lowercased() < $1.project.lowercased() }
    }

    var failingCount: Int { statuses.filter { $0.state == .failed }.count }
    var waitingCount: Int { statuses.filter { $0.state == .waitingApproval }.count }
    var runningCount: Int { statuses.filter { $0.state == .running }.count }
    var succeededCount: Int { statuses.filter { $0.state == .succeeded }.count }

    /// Live lookup so a pushed detail screen tracks refreshes.
    func status(forKey key: String) -> PipelineStatus? {
        statuses.first { $0.key == key }
    }

    func refresh() async {
        guard config.isConfigured else {
            problem = statuses.isEmpty ? nil : problem
            return
        }
        guard let client = AzureDevOpsClient.make(config: config.snapshot) else {
            problem = "Missing PAT — add it in Settings."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let result = await client.fetchAll(projects: config.projects)
        statuses = result.statuses
        problem = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n")
        lastUpdated = Date()

        // Keep the notification baseline current so foreground refreshes also
        // drive transition notifications (and don't replay on next background run).
        await NotificationService.shared.processTransitions(
            statuses: result.statuses,
            hadError: !result.errors.isEmpty,
            config: config.snapshot)
    }

    func run(ref: RunRef, branch: String?) async {
        guard let client = AzureDevOpsClient.make(config: config.snapshot) else { return }
        let result = await client.run(ref: ref, branch: branch)
        await NotificationService.shared.post(result: result)
        actionBanner = result.body
        if result.success { await refresh() }
    }

    func decide(ref: ApprovalRef, approve: Bool, comment: String) async {
        guard let client = AzureDevOpsClient.make(config: config.snapshot) else { return }
        let result = await client.decide(ref: ref, approve: approve, comment: comment)
        await NotificationService.shared.post(result: result)
        actionBanner = result.body
        if result.success { await refresh() }
    }
}
