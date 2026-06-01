import Foundation
import Security

// MARK: - KeychainHelper
//
// Generic Keychain wrapper for `kSecClassGenericPassword` items keyed by
// (service, account). We don't ask for biometric protection or sharing
// across apps — the default keychain class is enough for password storage
// that survives across launches and benefits from device-passcode encryption.
//
// Why not Codable + UserDefaults? UserDefaults is plaintext on the device
// and ends up in iCloud / iTunes backups verbatim. Keychain entries are
// encrypted with the user passcode/biometrics and are filtered out of
// most backup paths by default.

enum KeychainError: Error {
    case readFailed(OSStatus)
}

enum KeychainHelper {
    /// Stores or replaces a UTF-8 password under (service, account).
    @discardableResult
    static func set(_ password: String, service: String, account: String) -> Bool {
        let data  = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Atomic upsert: try to update existing item first; add if not found.
        // This avoids the race window of delete-then-add.
        let updateAttrs: [String: Any] = [
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String]      = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            Task { @MainActor in LogStore.shared.log(.connection,
                "⚠ Keychain add failed (\(service)/\(account)): \(addStatus)") }
            return false
        }

        Task { @MainActor in LogStore.shared.log(.connection,
            "⚠ Keychain update failed (\(service)/\(account)): \(updateStatus)") }
        return false
    }

    /// Returns the password for (service, account), or nil when the item does
    /// not exist. A genuine Keychain error (device locked, corrupted entry,
    /// entitlement missing) is also returned as nil but **logged** so the
    /// difference is visible in the provisioning/connection log.
    ///
    /// Callers that need to distinguish "not found" from "error" can check
    /// the provisioning log, or call `getResult(service:account:)` directly.
    static func get(service: String, account: String) -> String? {
        switch getResult(service: service, account: account) {
        case .success(let value):
            return value
        case .failure(let error):
            if case .readFailed(let status) = error {
                Task { @MainActor in
                    LogStore.shared.log(.connection,
                        "⚠ Keychain read error (\(service)/\(account)): OSStatus \(status)")
                }
            }
            return nil
        }
    }

    /// Lower-level read that distinguishes "item not found" (`.success(nil)`)
    /// from a genuine Keychain error (`.failure(.readFailed(OSStatus))`).
    static func getResult(service: String, account: String) -> Result<String?, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return .failure(.readFailed(status)) }
        return .success(string)
    }

    /// Removes the password for (service, account). No-op if it doesn't exist.
    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Task { @MainActor in LogStore.shared.log(.connection,
                "⚠ Keychain delete failed (OSStatus \(status)) for \(service)/\(account)") }
        }
    }
}
