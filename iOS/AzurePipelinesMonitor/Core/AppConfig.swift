import Foundation
import Combine

/// User-editable configuration, persisted in UserDefaults. Replaces the
/// macOS app's ~/.config/AzurePipelinesMonitor/config.json.
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @Published var organization: String {
        didSet { defaults.set(organization, forKey: Keys.organization) }
    }
    @Published var projects: [String] {
        didSet { defaults.set(projects, forKey: Keys.projects) }
    }
    /// Background-refresh cadence hint (seconds). iOS ultimately decides timing.
    @Published var refreshSeconds: Double {
        didSet { defaults.set(refreshSeconds, forKey: Keys.refreshSeconds) }
    }
    @Published var notifyOnStart: Bool {
        didSet { defaults.set(notifyOnStart, forKey: Keys.notifyOnStart) }
    }
    @Published var notifyOnComplete: Bool {
        didSet { defaults.set(notifyOnComplete, forKey: Keys.notifyOnComplete) }
    }
    @Published var notifyOnApproval: Bool {
        didSet { defaults.set(notifyOnApproval, forKey: Keys.notifyOnApproval) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let organization = "organization"
        static let projects = "projects"
        static let refreshSeconds = "refreshSeconds"
        static let notifyOnStart = "notifyOnStart"
        static let notifyOnComplete = "notifyOnComplete"
        static let notifyOnApproval = "notifyOnApproval"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        organization = defaults.string(forKey: Keys.organization) ?? ""
        projects = defaults.stringArray(forKey: Keys.projects) ?? []
        refreshSeconds = defaults.object(forKey: Keys.refreshSeconds) as? Double ?? 60
        notifyOnStart = defaults.object(forKey: Keys.notifyOnStart) as? Bool ?? true
        notifyOnComplete = defaults.object(forKey: Keys.notifyOnComplete) as? Bool ?? true
        notifyOnApproval = defaults.object(forKey: Keys.notifyOnApproval) as? Bool ?? true
    }

    /// A non-observable snapshot safe to read from the background task.
    var snapshot: Snapshot {
        Snapshot(organization: organization,
                 projects: projects,
                 notifyOnStart: notifyOnStart,
                 notifyOnComplete: notifyOnComplete,
                 notifyOnApproval: notifyOnApproval)
    }

    struct Snapshot: Sendable {
        let organization: String
        let projects: [String]
        let notifyOnStart: Bool
        let notifyOnComplete: Bool
        let notifyOnApproval: Bool

        /// Loads directly from UserDefaults so the background task doesn't
        /// touch the @MainActor AppConfig.
        static func load(from defaults: UserDefaults = .standard) -> Snapshot {
            Snapshot(
                organization: defaults.string(forKey: Keys.organization) ?? "",
                projects: defaults.stringArray(forKey: Keys.projects) ?? [],
                notifyOnStart: defaults.object(forKey: Keys.notifyOnStart) as? Bool ?? true,
                notifyOnComplete: defaults.object(forKey: Keys.notifyOnComplete) as? Bool ?? true,
                notifyOnApproval: defaults.object(forKey: Keys.notifyOnApproval) as? Bool ?? true)
        }
    }

    var isConfigured: Bool {
        !organization.isEmpty && !projects.isEmpty && Keychain.hasPAT
    }
}
