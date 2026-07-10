import Foundation
import UserNotifications
import UIKit

/// Posts local notifications on pipeline transitions and action confirmations.
/// The transition-diffing logic is ported from the macOS app's
/// `sendTransitionNotifications` / `finishRefresh`; the baseline is persisted in
/// UserDefaults so the foreground app and the background task share one view of
/// "what was true last time".
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private let defaults = UserDefaults.standard
    private let baselineKey = "previousStates"
    private let hasBaselineKey = "hasBaseline"

    private struct Previous: Codable {
        let buildID: Int
        let state: PipelineState
    }

    // MARK: Authorization

    func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func authorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    // MARK: Transition diffing

    private func loadBaseline() -> [String: Previous] {
        guard let data = defaults.data(forKey: baselineKey),
              let map = try? JSONDecoder().decode([String: Previous].self, from: data)
        else { return [:] }
        return map
    }

    private func saveBaseline(_ statuses: [PipelineStatus]) {
        let map = Dictionary(uniqueKeysWithValues: statuses.map {
            ($0.key, Previous(buildID: $0.buildID, state: $0.state))
        })
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: baselineKey)
        }
    }

    /// Diffs `statuses` against the stored baseline, posts notifications for any
    /// changes, then records the new baseline. Only notifies once a baseline
    /// exists, so the first successful fetch never replays current state as news.
    func processTransitions(statuses: [PipelineStatus], hadError: Bool,
                            config: AppConfig.Snapshot) async {
        let previous = loadBaseline()
        let hasBaseline = defaults.bool(forKey: hasBaselineKey)

        if hasBaseline {
            for status in statuses {
                await sendTransitionNotification(for: status,
                                                 previous: previous[status.key],
                                                 config: config)
            }
        }
        saveBaseline(statuses)
        if !statuses.isEmpty || !hadError {
            defaults.set(true, forKey: hasBaselineKey)
        }
    }

    private func sendTransitionNotification(for status: PipelineStatus,
                                            previous: Previous?,
                                            config: AppConfig.Snapshot) async {
        let isNewBuild = previous == nil || previous!.buildID != status.buildID
        let wasActive = previous != nil
            && (previous!.state == .running || previous!.state == .waitingApproval)

        switch status.state {
        case .running:
            if isNewBuild {
                if config.notifyOnStart { await notify("🚀 Build started", for: status) }
            } else if previous?.state == .waitingApproval {
                if config.notifyOnApproval { await notify("▶️ Build approved & resumed", for: status) }
            }
        case .waitingApproval:
            if isNewBuild || previous?.state != .waitingApproval {
                if config.notifyOnApproval { await notify("✋ Approval required", for: status) }
            }
        case .succeeded:
            if config.notifyOnComplete && (isNewBuild ? previous != nil : wasActive) {
                await notify("✅ Build succeeded", for: status)
            }
        case .failed:
            if config.notifyOnComplete && (isNewBuild ? previous != nil : wasActive) {
                let title = status.detail == "partially succeeded"
                    ? "⚠️ Build partially succeeded" : "❌ Build failed"
                await notify(title, for: status)
            }
        case .canceled:
            if config.notifyOnComplete && (isNewBuild ? previous != nil : wasActive) {
                await notify("⏹ Build canceled", for: status)
            }
        case .other:
            break
        }
    }

    private func notify(_ title: String, for status: PipelineStatus) async {
        var body = "\(status.pipelineName) — #\(status.buildNumber)"
        if let branch = status.branch { body += " (\(branch))" }
        body += " · \(status.project)"
        await post(title: title, body: body, url: status.webURL)
    }

    // MARK: Raw posting (also used for action confirmations)

    func post(result: ActionResult) async {
        await post(title: result.title, body: result.body, url: nil)
    }

    func post(title: String, body: String, url: URL?) async {
        guard await authorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo = ["url": url.absoluteString] }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Test notification — re-requests authorization then posts a sample.
    func sendTest() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task {
                    await self.post(title: "🔔 Test notification",
                                    body: "Azure Pipelines Monitor can post notifications.",
                                    url: nil)
                }
            }
    }

    // MARK: Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            await UIApplication.shared.open(url)
        }
    }
}
