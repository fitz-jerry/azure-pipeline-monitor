import Foundation

/// Result of a fetch across all configured projects.
struct FetchResult: Sendable {
    let statuses: [PipelineStatus]
    let errors: [String]
}

/// Outcome of a Run or Approve/Reject action, ready to surface as a notification.
struct ActionResult: Sendable {
    let success: Bool
    let title: String
    let body: String
}

/// One project's fetch outcome. A plain enum (rather than Result) because
/// Result requires its failure type to conform to Error and we carry a message.
enum ProjectFetch: Sendable {
    case success([PipelineStatus])
    case failure(String)
}

enum AzureError: LocalizedError {
    case notConfigured
    case badProjectName(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set your organization, projects and PAT in Settings first."
        case .badProjectName(let p): return "\(p): bad project name"
        }
    }
}

/// Async Azure DevOps REST client. Ported from the macOS app's URLSession
/// completion-handler code (Sources/main.swift) to async/await.
struct AzureDevOpsClient: Sendable {
    let organization: String
    let pat: String

    private var authHeader: String {
        "Basic " + Data(":\(pat)".utf8).base64EncodedString()
    }

    private func request(url: URL, method: String = "GET",
                         jsonBody: Any? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        return request
    }

    /// Convenience factory that reads org from config and PAT from Keychain.
    static func make(config: AppConfig.Snapshot) -> AzureDevOpsClient? {
        guard !config.organization.isEmpty, let pat = Keychain.readPAT() else { return nil }
        return AzureDevOpsClient(organization: config.organization, pat: pat)
    }

    // MARK: - Fetch

    func buildsURL(project: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dev.azure.com"
        guard let encodedProject = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        components.percentEncodedPath = "/\(organization)/\(encodedProject)/_apis/build/builds"
        components.queryItems = [
            URLQueryItem(name: "maxBuildsPerDefinition", value: "1"),
            URLQueryItem(name: "queryOrder", value: "queueTimeDescending"),
            URLQueryItem(name: "$top", value: "200"),
            URLQueryItem(name: "api-version", value: "7.1"),
        ]
        return components.url
    }

    /// Fetches every project's latest runs concurrently and merges the results.
    func fetchAll(projects: [String]) async -> FetchResult {
        await withTaskGroup(of: ProjectFetch.self) { group in
            for project in projects {
                group.addTask { await fetch(project: project) }
            }
            var statuses: [PipelineStatus] = []
            var errors: [String] = []
            for await result in group {
                switch result {
                case .success(let s): statuses.append(contentsOf: s)
                case .failure(let e): errors.append(e)
                }
            }
            statuses.sort {
                ($0.project, $0.pipelineName.lowercased()) < ($1.project, $1.pipelineName.lowercased())
            }
            return FetchResult(statuses: statuses, errors: errors)
        }
    }

    /// Fetches a single project's pipelines. Returns statuses or an error string
    /// (never throws, so one bad project doesn't sink the whole refresh).
    func fetch(project: String) async -> ProjectFetch {
        guard let url = buildsURL(project: project) else {
            return .failure("\(project): bad project name")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url: url))
            guard let http = response as? HTTPURLResponse else {
                return .failure("\(project): no HTTP response")
            }
            // Azure DevOps answers 203 with an HTML sign-in page when the PAT is bad.
            guard http.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(BuildsResponse.self, from: data)
            else {
                let why = http.statusCode == 203 || http.statusCode == 401
                    ? "authentication failed — check the PAT (needs Build > Read, not expired)"
                    : "HTTP \(http.statusCode)"
                return .failure("\(project): \(why)")
            }

            var statuses: [PipelineStatus] = []
            for build in decoded.value {
                var status = pipelineStatus(from: build, project: project)
                // A running/queued build may actually be paused on an
                // environment approval; only the timeline reveals that.
                if ["inProgress", "notStarted", "postponed"].contains(build.status),
                   let approvalID = await pendingApproval(buildID: build.id, project: project) {
                    status.state = .waitingApproval
                    status.detail = "waiting for approval"
                    status.approvalID = approvalID
                }
                statuses.append(status)
            }
            return .success(statuses)
        } catch {
            return .failure("\(project): \(error.localizedDescription)")
        }
    }

    /// Returns the pending approval's id, or nil when nothing waits.
    private func pendingApproval(buildID: Int, project: String) async -> String? {
        guard let encodedProject = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://dev.azure.com/\(organization)/\(encodedProject)/_apis/build/builds/\(buildID)/timeline?api-version=7.1")
        else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url: url)),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TimelineResponse.self, from: data)
        else { return nil }
        let pending = decoded.records.first {
            $0.type == "Checkpoint.Approval" && $0.state != "completed"
        }
        return pending?.id
    }

    func pipelineStatus(from build: Build, project: String) -> PipelineStatus {
        let state: PipelineState
        let detail: String
        switch build.status {
        case "inProgress", "notStarted", "postponed":
            state = .running
            detail = build.status == "inProgress" ? "running" : "queued"
        default:
            switch build.result {
            case "succeeded":
                state = .succeeded; detail = "succeeded"
            case "failed":
                state = .failed; detail = "failed"
            case "partiallySucceeded":
                state = .failed; detail = "partially succeeded"
            case "canceled":
                state = .canceled; detail = "canceled"
            default:
                state = .other; detail = build.result ?? build.status ?? "unknown"
            }
        }
        let branch = build.sourceBranch.map {
            $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0
        }
        let webURL = build._links?.web?.href.flatMap(URL.init(string:))
        return PipelineStatus(
            key: "\(project)#\(build.definition.id)",
            buildID: build.id,
            definitionID: build.definition.id,
            project: project,
            pipelineName: build.definition.name,
            state: state,
            detail: detail,
            buildNumber: build.buildNumber ?? String(build.id),
            branch: branch,
            when: parseDate(build.finishTime ?? build.queueTime),
            webURL: webURL
        )
    }

    // MARK: - Run

    /// Queues a run of a pipeline definition. `branch` nil = pipeline default.
    func run(ref: RunRef, branch: String?) async -> ActionResult {
        guard let encodedProject = ref.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://dev.azure.com/\(organization)/\(encodedProject)/_apis/pipelines/\(ref.definitionID)/runs?api-version=7.1")
        else {
            return ActionResult(success: false, title: "⚠️ Run failed to queue",
                                body: "\(ref.pipelineName): bad project name")
        }
        var body: [String: Any] = [:]
        if let branch {
            let refName = branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)"
            body = ["resources": ["repositories": ["self": ["refName": refName]]]]
        }
        do {
            let (data, response) = try await URLSession.shared.data(
                for: request(url: url, method: "POST", jsonBody: body))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                return ActionResult(success: true, title: "🚀 Run queued",
                                    body: "\(ref.pipelineName) · \(ref.project)"
                                        + (branch.map { " (\($0))" } ?? ""))
            }
            var message = serverMessage(data) ?? "HTTP \(code)"
            if [203, 401, 403].contains(code) {
                message += " — the PAT needs the Build (Read & execute) scope."
            }
            return ActionResult(success: false, title: "⚠️ Run failed to queue", body: message)
        } catch {
            return ActionResult(success: false, title: "⚠️ Run failed to queue",
                                body: error.localizedDescription)
        }
    }

    // MARK: - Approve / Reject

    func decide(ref: ApprovalRef, approve: Bool, comment: String) async -> ActionResult {
        let verb = approve ? "Approval" : "Rejection"
        guard let encodedProject = ref.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://dev.azure.com/\(organization)/\(encodedProject)/_apis/pipelines/approvals?api-version=7.1-preview.1")
        else {
            return ActionResult(success: false, title: "⚠️ \(verb) failed",
                                body: "\(ref.pipelineName): bad project name")
        }
        let body: [[String: String]] = [[
            "approvalId": ref.approvalID,
            "status": approve ? "approved" : "rejected",
            "comment": comment,
        ]]
        do {
            let (data, response) = try await URLSession.shared.data(
                for: request(url: url, method: "PATCH", jsonBody: body))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                return ActionResult(success: true,
                                    title: approve ? "✅ Approved" : "⛔️ Rejected",
                                    body: "\(ref.pipelineName) · \(ref.project)")
            }
            var message = serverMessage(data) ?? "HTTP \(code)"
            if [203, 401, 403].contains(code) {
                message += " — the PAT likely needs the Build (Read & execute) scope, and you must be a listed approver."
            }
            return ActionResult(success: false, title: "⚠️ \(verb) failed", body: message)
        } catch {
            return ActionResult(success: false, title: "⚠️ \(verb) failed",
                                body: error.localizedDescription)
        }
    }

    private func serverMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String else { return nil }
        return message
    }
}
