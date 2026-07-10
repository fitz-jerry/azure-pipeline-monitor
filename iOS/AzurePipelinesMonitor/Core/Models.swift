import Foundation

// MARK: - Azure DevOps API models
// Ported from the macOS app (Sources/main.swift). Field names match the REST
// JSON so JSONDecoder maps them directly.

struct BuildsResponse: Codable {
    let value: [Build]
}

struct Build: Codable {
    struct Definition: Codable {
        let id: Int
        let name: String
    }
    struct Links: Codable {
        struct Web: Codable { let href: String? }
        let web: Web?
    }
    let id: Int
    let buildNumber: String?
    let status: String?
    let result: String?
    let queueTime: String?
    let finishTime: String?
    let sourceBranch: String?
    let definition: Definition
    let _links: Links?
}

struct TimelineResponse: Codable {
    let records: [TimelineRecord]
}

struct TimelineRecord: Codable {
    let id: String?
    let type: String?
    let state: String?
}

// MARK: - Display model

enum PipelineState: String, Codable, Sendable {
    case succeeded, failed, running, waitingApproval, canceled, other

    /// SF Symbol used to render the state in the list.
    var symbolName: String {
        switch self {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .waitingApproval: return "hand.raised.fill"
        case .canceled: return "minus.circle.fill"
        case .other: return "questionmark.circle.fill"
        }
    }

    /// Human-readable state name for the detail screen.
    var displayName: String {
        switch self {
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .running: return "Running"
        case .waitingApproval: return "Waiting for Approval"
        case .canceled: return "Canceled"
        case .other: return "Unknown"
        }
    }

    /// Emoji mirror of the macOS menu bar, reused in notification titles.
    var emoji: String {
        switch self {
        case .succeeded: return "✅"
        case .failed: return "❌"
        case .running: return "🔄"
        case .waitingApproval: return "✋"
        case .canceled: return "⏹"
        case .other: return "⚠️"
        }
    }
}

struct PipelineStatus: Identifiable, Sendable {
    let key: String          // project + definition id, stable across builds
    let buildID: Int
    let definitionID: Int
    let project: String
    let pipelineName: String
    var state: PipelineState
    var detail: String
    let buildNumber: String
    let branch: String?
    let when: Date?
    let webURL: URL?
    // The Checkpoint.Approval timeline record id doubles as the approval id
    // for the Approvals REST API.
    var approvalID: String? = nil

    var id: String { key }
}

/// Everything needed to queue a run for a pipeline definition.
struct RunRef: Sendable {
    let project: String
    let definitionID: Int
    let pipelineName: String
    let lastBranch: String?
    let webURL: URL?
}

/// Everything needed to approve or reject a pending environment approval.
struct ApprovalRef: Sendable {
    let project: String
    let approvalID: String
    let pipelineName: String
    let url: URL?
}

extension PipelineStatus {
    /// A run request for this pipeline's definition.
    var runRef: RunRef {
        RunRef(project: project, definitionID: definitionID,
               pipelineName: pipelineName, lastBranch: branch, webURL: webURL)
    }

    /// An approval reference, present only while waiting on an approval.
    var approvalRef: ApprovalRef? {
        guard let approvalID else { return nil }
        return ApprovalRef(project: project, approvalID: approvalID,
                           pipelineName: pipelineName, url: webURL)
    }
}

// MARK: - Date helpers

let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}

let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()
