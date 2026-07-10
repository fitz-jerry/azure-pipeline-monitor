import Foundation
import Security

/// Stores the Azure DevOps Personal Access Token in the iOS Keychain.
/// Mirrors the macOS app's Keychain item (service `AzurePipelinesMonitor`,
/// account `pat`) so the two apps use the same conventions.
enum Keychain {
    static let service = "AzurePipelinesMonitor"
    static let account = "pat"

    /// OSStatus of the last write/delete, so the UI can explain a failure.
    static private(set) var lastStatus: OSStatus = errSecSuccess

    /// True when the last failure was -34018 (app not signed with a keychain
    /// entitlement) — fixed by running from Xcode with a signing team.
    static var lastFailureWasMissingEntitlement: Bool {
        lastStatus == errSecMissingEntitlement
    }

    /// Human-readable message for an OSStatus (e.g. -34018 → missing entitlement).
    static func message(for status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
        return "\(text) (\(status))"
    }

    static func readPAT() -> String? {
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

    @discardableResult
    static func writePAT(_ pat: String) -> Bool {
        let trimmed = pat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deletePAT() }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(trimmed.utf8)
        // Try update first; fall back to add if the item doesn't exist yet.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            lastStatus = addStatus
            return addStatus == errSecSuccess
        }
        lastStatus = status
        return status == errSecSuccess
    }

    @discardableResult
    static func deletePAT() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static var hasPAT: Bool { readPAT() != nil }
}
