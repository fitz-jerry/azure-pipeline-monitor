import Foundation
import WatchConnectivity

/// iPhone side of the Watch sync. Pushes the current organization, projects, and
/// PAT to the Watch as the WCSession application context (latest-state delivery,
/// sent in the background). Call `sync()` whenever settings change.
final class PhoneConnectivity: NSObject, WCSessionDelegate {
    static let shared = PhoneConnectivity()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the latest config + PAT to the Watch. Safe to call often.
    func sync() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let config = AppConfig.shared
        var context: [String: Any] = [
            WCKeys.organization: config.organization,
            WCKeys.projects: config.projects,
        ]
        if let pat = Keychain.readPAT() {
            context[WCKeys.pat] = pat
        }
        try? session.updateApplicationContext(context)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // Push current state as soon as the session is ready.
        if activationState == .activated {
            DispatchQueue.main.async { self.sync() }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for a newly paired Watch.
        session.activate()
    }
}
