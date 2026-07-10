import Foundation
import BackgroundTasks

/// Schedules and handles the periodic background poll. iOS decides the actual
/// timing (BGAppRefreshTask is throttled and best-effort — it will not honor a
/// fixed interval like the macOS app does), so notification delivery here is
/// opportunistic rather than guaranteed.
enum BackgroundRefresh {
    static let taskIdentifier = "com.axial.azurepipelinesmonitor.refresh"

    /// Registered once at launch. Must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { task in
            handle(task: task as! BGAppRefreshTask)
        }
    }

    /// Ask iOS to run the task again. Called at launch and after each run.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        // Earliest — iOS may run it much later.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(task: BGAppRefreshTask) {
        schedule() // always line up the next one first

        let work = Task {
            let config = AppConfig.Snapshot.load()
            guard !config.projects.isEmpty,
                  let client = AzureDevOpsClient.make(config: config) else {
                task.setTaskCompleted(success: false)
                return
            }
            let result = await client.fetchAll(projects: config.projects)
            await NotificationService.shared.processTransitions(
                statuses: result.statuses,
                hadError: !result.errors.isEmpty,
                config: config)
            task.setTaskCompleted(success: result.errors.isEmpty)
        }

        task.expirationHandler = { work.cancel() }
    }
}
