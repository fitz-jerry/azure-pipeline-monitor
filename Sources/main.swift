import Cocoa
import Security
import UserNotifications

// MARK: - Config

struct Config: Codable {
    var organization: String
    var projects: [String]
    var refreshSeconds: Double?
    var keychainService: String?
    var keychainAccount: String?
    var notifyOnStart: Bool?
    var notifyOnComplete: Bool?
    var notifyOnApproval: Bool?
}

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/AzurePipelinesMonitor")
let configURL = configDir.appendingPathComponent("config.json")

func loadConfig() -> Config? {
    guard let data = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: data)
}

func readPAT(service: String, account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let pat = String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
          !pat.isEmpty
    else { return nil }
    return pat
}

// MARK: - Azure DevOps models

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

enum PipelineState {
    case succeeded, failed, running, waitingApproval, canceled, other
}

struct PipelineStatus {
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
}

final class ApprovalRef: NSObject {
    let project: String
    let approvalID: String
    let pipelineName: String
    let url: URL?
    init(project: String, approvalID: String, pipelineName: String, url: URL?) {
        self.project = project
        self.approvalID = approvalID
        self.pipelineName = pipelineName
        self.url = url
    }
}

final class RunRef: NSObject {
    let project: String
    let definitionID: Int
    let pipelineName: String
    let lastBranch: String?
    init(project: String, definitionID: Int, pipelineName: String, lastBranch: String?) {
        self.project = project
        self.definitionID = definitionID
        self.pipelineName = pipelineName
        self.lastBranch = lastBranch
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

let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/AzurePipelinesMonitor.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

// MARK: - Thread-safe result collector

final class Collector {
    private let lock = NSLock()
    private(set) var statuses: [PipelineStatus] = []
    private(set) var errors: [String] = []

    func add(_ status: PipelineStatus) {
        lock.lock(); statuses.append(status); lock.unlock()
    }
    func addError(_ message: String) {
        lock.lock(); errors.append(message); lock.unlock()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var config: Config?
    var statuses: [PipelineStatus] = []
    var problem: String?
    var lastUpdated: Date?
    var previousStates: [String: (buildID: Int, state: PipelineState)] = [:]
    var hasBaseline = false
    var notificationsAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusEmoji("⏳")
        rebuildMenu()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.notificationsAllowed = granted
            log("notification authorization: granted=\(granted)"
                + (error.map { " error=\($0)" } ?? ""))
            center.getNotificationSettings { settings in
                log("notification settings: authorizationStatus=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue)")
            }
        }

        start()
    }

    func start() {
        timer?.invalidate()
        config = loadConfig()
        let interval = max(15, config?.refreshSeconds ?? 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // MARK: Refresh

    @objc func refreshNow() {
        // Re-read the config so edits are picked up without relaunching.
        start()
    }

    func refresh() {
        guard let config, !config.organization.isEmpty, config.organization != "YOUR_ORG" else {
            statuses = []
            problem = "Not configured yet — open the config file, set your organization and projects, then choose Refresh."
            updateUI()
            return
        }
        let service = config.keychainService ?? "AzurePipelinesMonitor"
        let account = config.keychainAccount ?? "pat"
        guard let pat = readPAT(service: service, account: account) else {
            statuses = []
            problem = "No PAT found in Keychain (service \"\(service)\", account \"\(account)\")."
            updateUI()
            return
        }
        let auth = "Basic " + Data(":\(pat)".utf8).base64EncodedString()

        let group = DispatchGroup()
        let collector = Collector()
        for project in config.projects {
            fetchProject(project, organization: config.organization, auth: auth,
                         group: group, collector: collector)
        }
        group.notify(queue: .main) {
            self.finishRefresh(results: collector.statuses, errors: collector.errors)
        }
    }

    func fetchProject(_ project: String, organization: String, auth: String,
                      group: DispatchGroup, collector: Collector) {
        guard let url = buildsURL(organization: organization, project: project) else {
            collector.addError("\(project): bad project name")
            return
        }
        var request = URLRequest(url: url)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        group.enter()
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { group.leave() }
            if let error {
                collector.addError("\(project): \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            // Azure DevOps answers 203 with an HTML sign-in page when the PAT is bad.
            guard http.statusCode == 200, let data,
                  let decoded = try? JSONDecoder().decode(BuildsResponse.self, from: data)
            else {
                let why = http.statusCode == 203 || http.statusCode == 401
                    ? "authentication failed — check the PAT (needs Build > Read, not expired)"
                    : "HTTP \(http.statusCode)"
                collector.addError("\(project): \(why)")
                return
            }
            for build in decoded.value {
                let status = self.pipelineStatus(from: build, project: project)
                // A running build may actually be paused on an environment
                // approval; only the timeline reveals that. An approval gating
                // the first stage leaves the build in notStarted, so queued
                // builds need the check too.
                if ["inProgress", "notStarted", "postponed"].contains(build.status) {
                    group.enter()
                    self.checkForPendingApproval(buildID: build.id, project: project,
                                                 organization: organization, auth: auth) { approvalID in
                        var status = status
                        if let approvalID {
                            status.state = .waitingApproval
                            status.detail = "waiting for approval"
                            status.approvalID = approvalID
                        }
                        collector.add(status)
                        group.leave()
                    }
                } else {
                    collector.add(status)
                }
            }
        }.resume()
    }

    /// Calls back with the pending approval's id, or nil when nothing waits.
    func checkForPendingApproval(buildID: Int, project: String, organization: String,
                                 auth: String, completion: @escaping (String?) -> Void) {
        guard let encodedProject = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://dev.azure.com/\(organization)/\(encodedProject)/_apis/build/builds/\(buildID)/timeline?api-version=7.1")
        else { completion(nil); return }
        var request = URLRequest(url: url)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let decoded = try? JSONDecoder().decode(TimelineResponse.self, from: data)
            else { completion(nil); return }
            let pending = decoded.records.first {
                $0.type == "Checkpoint.Approval" && $0.state != "completed"
            }
            completion(pending?.id)
        }.resume()
    }

    func finishRefresh(results: [PipelineStatus], errors: [String]) {
        statuses = results.sorted {
            ($0.project, $0.pipelineName.lowercased()) < ($1.project, $1.pipelineName.lowercased())
        }
        problem = errors.isEmpty ? nil : errors.joined(separator: "\n")
        lastUpdated = Date()

        if hasBaseline {
            for status in statuses {
                sendTransitionNotifications(for: status, previous: previousStates[status.key])
            }
        }
        previousStates = Dictionary(uniqueKeysWithValues: statuses.map {
            ($0.key, (buildID: $0.buildID, state: $0.state))
        })
        // Only notify once we have a baseline from a successful fetch, so a
        // fresh launch doesn't replay the current state as "news".
        if !statuses.isEmpty || problem == nil { hasBaseline = true }

        writeSnapshot()
        updateUI()
    }

    // MARK: Snapshot for the desktop widget

    struct Snapshot: Codable {
        struct Pipeline: Codable {
            let project: String
            let name: String
            let state: String
            let detail: String
            let when: Date?
        }
        let updated: Date
        let pipelines: [Pipeline]
    }

    static let widgetBundleID = "com.axial.azurepipelineswidget.widget"

    func writeSnapshot() {
        let pipelines = statuses.map { status -> Snapshot.Pipeline in
            let state: String
            switch status.state {
            case .succeeded: state = "succeeded"
            case .failed: state = "failed"
            case .running: state = "running"
            case .waitingApproval: state = "waitingApproval"
            case .canceled: state = "canceled"
            case .other: state = "other"
            }
            return Snapshot.Pipeline(project: status.project, name: status.pipelineName,
                                     state: state, detail: status.detail, when: status.when)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Snapshot(updated: Date(), pipelines: pipelines))
        else { return }

        // Write to the real home and, if the widget's sandbox container exists,
        // to the same relative path inside it — whichever way the widget
        // resolves ~, it finds a current snapshot.
        let relativePath = "Library/Application Support/AzurePipelinesMonitor/status.json"
        let home = FileManager.default.homeDirectoryForCurrentUser
        var targets = [home.appendingPathComponent(relativePath)]
        let container = home.appendingPathComponent("Library/Containers/\(Self.widgetBundleID)/Data")
        if FileManager.default.fileExists(atPath: container.path) {
            targets.append(container.appendingPathComponent(relativePath))
        }
        for url in targets {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Notifications

    func sendTransitionNotifications(for status: PipelineStatus,
                                     previous: (buildID: Int, state: PipelineState)?) {
        let notifyStart = config?.notifyOnStart ?? true
        let notifyComplete = config?.notifyOnComplete ?? true
        let notifyApproval = config?.notifyOnApproval ?? true

        let isNewBuild = previous == nil || previous!.buildID != status.buildID
        let wasActive = previous != nil
            && (previous!.state == .running || previous!.state == .waitingApproval)

        switch status.state {
        case .running:
            if isNewBuild {
                if notifyStart { notify("🚀 Build started", for: status) }
            } else if previous?.state == .waitingApproval {
                if notifyApproval { notify("▶️ Build approved & resumed", for: status) }
            }
        case .waitingApproval:
            if isNewBuild || previous?.state != .waitingApproval {
                if notifyApproval { notify("✋ Approval required", for: status) }
            }
        case .succeeded:
            if notifyComplete && (isNewBuild ? previous != nil : wasActive) {
                notify("✅ Build succeeded", for: status)
            }
        case .failed:
            if notifyComplete && (isNewBuild ? previous != nil : wasActive) {
                let title = status.detail == "partially succeeded"
                    ? "⚠️ Build partially succeeded" : "❌ Build failed"
                notify(title, for: status)
            }
        case .canceled:
            if notifyComplete && (isNewBuild ? previous != nil : wasActive) {
                notify("⏹ Build canceled", for: status)
            }
        case .other:
            break
        }
    }

    func notify(_ title: String, for status: PipelineStatus) {
        var body = "\(status.pipelineName) — #\(status.buildNumber)"
        if let branch = status.branch { body += " (\(branch))" }
        body += " · \(status.project)"
        notifyRaw(title: title, body: body, url: status.webURL)
    }

    func notifyRaw(title: String, body: String, url: URL?) {
        guard notificationsAllowed else {
            log("notification suppressed (not authorized): \(title)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url {
            content.userInfo = ["url": url.absoluteString]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log("notification add failed: \(error)") }
        }
    }

    @objc func sendTestNotification() {
        // Re-request authorization so a previously failed registration gets
        // another chance to show the system prompt.
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                self.notificationsAllowed = granted
                log("test: authorization granted=\(granted)"
                    + (error.map { " error=\($0)" } ?? ""))
                DispatchQueue.main.async {
                    self.notifyRaw(title: "🔔 Test notification",
                                   body: "Azure Pipelines Monitor can reach Notification Center.",
                                   url: nil)
                }
            }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    // MARK: Azure DevOps mapping

    func buildsURL(organization: String, project: String) -> URL? {
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

    // MARK: UI

    func updateUI() {
        let failed = statuses.filter { $0.state == .failed }.count
        let awaiting = statuses.filter { $0.state == .waitingApproval }.count
        let running = statuses.filter { $0.state == .running }.count

        if statuses.isEmpty && problem != nil {
            setStatusEmoji("⚠️")
        } else if failed > 0 {
            setStatusEmoji("❌", count: failed)
        } else if awaiting > 0 {
            setStatusEmoji("✋", count: awaiting)
        } else if running > 0 {
            setStatusEmoji("🔄")
        } else if !statuses.isEmpty {
            setStatusEmoji("✅")
        } else {
            setStatusEmoji("❔")
        }
        rebuildMenu()
    }

    func setStatusEmoji(_ emoji: String, count: Int? = nil) {
        statusItem.button?.image = nil
        statusItem.button?.title = count.map { "\(emoji) \($0)" } ?? emoji
    }

    func rebuildMenu() {
        let menu = NSMenu()

        if let problem {
            for line in problem.split(separator: "\n") {
                let item = NSMenuItem(title: "⚠️ \(line)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        var currentProject: String?
        for status in statuses {
            if status.project != currentProject {
                currentProject = status.project
                let header = NSMenuItem(title: status.project.uppercased(), action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            let emoji: String
            switch status.state {
            case .succeeded: emoji = "✅"
            case .failed: emoji = "❌"
            case .running: emoji = "🔄"
            case .waitingApproval: emoji = "✋"
            case .canceled: emoji = "⏹"
            case .other: emoji = "▫️"
            }
            var title = "\(emoji) \(status.pipelineName) — \(status.detail)"
            if let when = status.when {
                title += " (\(relativeFormatter.localizedString(for: when, relativeTo: Date())))"
            }
            let item = NSMenuItem(title: title, action: #selector(openBuild(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = status.webURL
            if let branch = status.branch {
                item.toolTip = "Branch: \(branch) — click to open in Azure DevOps"
            }
            let submenu = NSMenu()
            if status.state == .waitingApproval, let approvalID = status.approvalID {
                let ref = ApprovalRef(project: status.project, approvalID: approvalID,
                                      pipelineName: status.pipelineName, url: status.webURL)
                let approveItem = NSMenuItem(title: "Approve…", action: #selector(approveFromMenu(_:)), keyEquivalent: "")
                approveItem.target = self
                approveItem.representedObject = ref
                submenu.addItem(approveItem)
                let rejectItem = NSMenuItem(title: "Reject…", action: #selector(rejectFromMenu(_:)), keyEquivalent: "")
                rejectItem.target = self
                rejectItem.representedObject = ref
                submenu.addItem(rejectItem)
                submenu.addItem(.separator())
            }
            let runItem = NSMenuItem(title: "Run Pipeline…", action: #selector(runFromMenu(_:)), keyEquivalent: "")
            runItem.target = self
            runItem.representedObject = RunRef(project: status.project, definitionID: status.definitionID,
                                               pipelineName: status.pipelineName, lastBranch: status.branch)
            submenu.addItem(runItem)
            let openItem = NSMenuItem(title: "Open Latest Run in Azure DevOps", action: #selector(openBuild(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = status.webURL
            submenu.addItem(openItem)
            item.submenu = submenu
            menu.addItem(item)
        }

        if statuses.isEmpty && problem == nil {
            let item = NSMenuItem(title: "No pipeline runs found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if let lastUpdated {
            let item = NSMenuItem(title: "Updated \(clockFormatter.string(from: lastUpdated))",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let configItem = NSMenuItem(title: "Open Config File", action: #selector(openConfig), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)
        let testItem = NSMenuItem(title: "Send Test Notification", action: #selector(sendTestNotification), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        if let organization = config?.organization, organization != "YOUR_ORG", !organization.isEmpty {
            let webItem = NSMenuItem(title: "Open Azure DevOps", action: #selector(openOrg), keyEquivalent: "")
            webItem.target = self
            menu.addItem(webItem)
        }
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: Approvals

    @objc func approveFromMenu(_ sender: NSMenuItem) { promptForDecision(sender, approve: true) }
    @objc func rejectFromMenu(_ sender: NSMenuItem) { promptForDecision(sender, approve: false) }

    func promptForDecision(_ sender: NSMenuItem, approve: Bool) {
        guard let ref = sender.representedObject as? ApprovalRef else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = approve
            ? "Approve “\(ref.pipelineName)”?"
            : "Reject “\(ref.pipelineName)”?"
        alert.informativeText = approve
            ? "The paused stage in \(ref.project) will continue running."
            : "The paused stage in \(ref.project) will be rejected and the run will fail."
        if !approve { alert.alertStyle = .warning }
        let commentField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        commentField.placeholderString = "Optional comment"
        alert.accessoryView = commentField
        alert.addButton(withTitle: approve ? "Approve" : "Reject")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let comment = commentField.stringValue.isEmpty
            ? "\(approve ? "Approved" : "Rejected") via Azure Pipelines Monitor"
            : commentField.stringValue
        submitApprovalDecision(ref: ref, approve: approve, comment: comment)
    }

    func submitApprovalDecision(ref: ApprovalRef, approve: Bool, comment: String) {
        guard let config else { return }
        let service = config.keychainService ?? "AzurePipelinesMonitor"
        let account = config.keychainAccount ?? "pat"
        guard let pat = readPAT(service: service, account: account),
              let encodedProject = ref.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://dev.azure.com/\(config.organization)/\(encodedProject)/_apis/pipelines/approvals?api-version=7.1-preview.1")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Basic " + Data(":\(pat)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let body: [[String: String]] = [[
            "approvalId": ref.approvalID,
            "status": approve ? "approved" : "rejected",
            "comment": comment,
        ]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let verb = approve ? "Approval" : "Rejection"
                if let error {
                    log("approval submit error: \(error)")
                    self.notifyRaw(title: "⚠️ \(verb) failed",
                                   body: error.localizedDescription, url: ref.url)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    log("approval \(ref.approvalID) \(approve ? "approved" : "rejected")")
                    self.notifyRaw(title: approve ? "✅ Approved" : "⛔️ Rejected",
                                   body: "\(ref.pipelineName) · \(ref.project)", url: ref.url)
                    self.refresh()
                } else {
                    var message = "HTTP \(code)"
                    if let data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let serverMessage = json["message"] as? String {
                        message = serverMessage
                    }
                    if [203, 401, 403].contains(code) {
                        message += " — the PAT likely needs the Build (Read & execute) scope, and you must be a listed approver."
                    }
                    log("approval submit failed (\(code)): \(message)")
                    self.notifyRaw(title: "⚠️ \(verb) failed", body: message, url: ref.url)
                }
            }
        }.resume()
    }

    // MARK: Manual runs

    @objc func runFromMenu(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? RunRef else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Run “\(ref.pipelineName)”?"
        alert.informativeText = "Queues a new run in \(ref.project). Leave the branch empty to use the pipeline's default."
        let branchField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        branchField.placeholderString = "Branch (empty = pipeline default)"
        // Pre-fill with the last run's branch — but not PR merge refs
        // (refs/pull/…), which can't be queued directly.
        if let last = ref.lastBranch, !last.hasPrefix("refs/") {
            branchField.stringValue = last
        }
        alert.accessoryView = branchField
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let branch = branchField.stringValue.trimmingCharacters(in: .whitespaces)
        submitRun(ref: ref, branch: branch.isEmpty ? nil : branch)
    }

    func submitRun(ref: RunRef, branch: String?) {
        guard let config else { return }
        let service = config.keychainService ?? "AzurePipelinesMonitor"
        let account = config.keychainAccount ?? "pat"
        guard let pat = readPAT(service: service, account: account),
              let encodedProject = ref.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://dev.azure.com/\(config.organization)/\(encodedProject)/_apis/pipelines/\(ref.definitionID)/runs?api-version=7.1")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data(":\(pat)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        var body: [String: Any] = [:]
        if let branch {
            let refName = branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)"
            body = ["resources": ["repositories": ["self": ["refName": refName]]]]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    log("run submit error: \(error)")
                    self.notifyRaw(title: "⚠️ Run failed to queue",
                                   body: error.localizedDescription, url: nil)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(code) {
                    log("queued run of definition \(ref.definitionID) (\(ref.pipelineName))"
                        + (branch.map { " on \($0)" } ?? ""))
                    self.notifyRaw(title: "🚀 Run queued",
                                   body: "\(ref.pipelineName) · \(ref.project)"
                                       + (branch.map { " (\($0))" } ?? ""),
                                   url: nil)
                    self.refresh()
                } else {
                    var message = "HTTP \(code)"
                    if let data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let serverMessage = json["message"] as? String {
                        message = serverMessage
                    }
                    if [203, 401, 403].contains(code) {
                        message += " — the PAT needs the Build (Read & execute) scope."
                    }
                    log("run submit failed (\(code)): \(message)")
                    self.notifyRaw(title: "⚠️ Run failed to queue", body: message, url: nil)
                }
            }
        }.resume()
    }

    // MARK: Actions

    @objc func openBuild(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openConfig() {
        NSWorkspace.shared.open(configURL)
    }

    @objc func openOrg() {
        if let organization = config?.organization,
           let url = URL(string: "https://dev.azure.com/\(organization)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
