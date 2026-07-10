import Foundation

/// Keys for the WatchConnectivity application-context payload the iPhone sends
/// to the Watch (organization, projects, and PAT). Shared by both targets.
enum WCKeys {
    static let organization = "org"
    static let projects = "projects"
    static let pat = "pat"
}
