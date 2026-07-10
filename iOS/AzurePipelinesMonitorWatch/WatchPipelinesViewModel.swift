import Foundation
import SwiftUI

@MainActor
final class WatchPipelinesViewModel: ObservableObject {
    @Published var statuses: [PipelineStatus] = []
    @Published var problem: String?
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    private let config: AppConfig

    init(config: AppConfig = .shared) {
        self.config = config
    }

    var failingCount: Int { statuses.filter { $0.state == .failed }.count }
    var waitingCount: Int { statuses.filter { $0.state == .waitingApproval }.count }
    var runningCount: Int { statuses.filter { $0.state == .running }.count }
    var succeededCount: Int { statuses.filter { $0.state == .succeeded }.count }

    var isConfigured: Bool { config.isConfigured }

    func status(forKey key: String) -> PipelineStatus? {
        statuses.first { $0.key == key }
    }

    func refresh() async {
        guard config.isConfigured,
              let client = AzureDevOpsClient.make(config: config.snapshot) else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let result = await client.fetchAll(projects: config.projects)
        statuses = result.statuses
        problem = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n")
        lastUpdated = Date()
    }

    func decide(ref: ApprovalRef, approve: Bool, comment: String) async -> ActionResult? {
        guard let client = AzureDevOpsClient.make(config: config.snapshot) else { return nil }
        let result = await client.decide(ref: ref, approve: approve, comment: comment)
        if result.success { await refresh() }
        return result
    }
}
