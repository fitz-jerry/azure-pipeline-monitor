import Foundation
import WatchConnectivity

/// Watch side of the sync. Receives the iPhone's application context (org,
/// projects, PAT) and persists it locally: config to UserDefaults, PAT to the
/// Watch Keychain. Calls `onUpdate` so the UI can refresh.
final class WatchConnectivityReceiver: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityReceiver()

    /// Invoked on the main thread after new credentials are applied.
    var onUpdate: (() -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func apply(_ context: [String: Any]) {
        guard !context.isEmpty else { return }
        DispatchQueue.main.async {
            if let org = context[WCKeys.organization] as? String {
                AppConfig.shared.organization = org
            }
            if let projects = context[WCKeys.projects] as? [String] {
                AppConfig.shared.projects = projects
            }
            if let pat = context[WCKeys.pat] as? String {
                Keychain.writePAT(pat)
            } else {
                Keychain.deletePAT()
            }
            self.onUpdate?()
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // Apply whatever the phone last sent, even if we activated after it.
        apply(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        apply(context)
    }
}
