import Foundation

// MARK: - ConnectionSecretStore
//
// Keychain wrapper for per-connection secrets: the encryption key and,
// optionally, the SOCKS5 password. Neither is written to UserDefaults —
// both are encrypted by iOS under the device passcode.
//
// Two separate Keychain services keep the two secret types logically
// independent. The account key for both is the ConnectionRecord's UUID.

enum ConnectionSecretStore {
    private static let keyService      = "olcrtc.connection.key"
    private static let socksPassService = "olcrtc.connection.sockspass"
    private static let wbTokenService   = "olcrtc.connection.wbtoken"   // #436

    // MARK: Encryption key

    static func setKey(connectionID: UUID, key: String) {
        KeychainHelper.set(key, service: keyService, account: connectionID.uuidString)
    }

    static func key(for connectionID: UUID) -> String? {
        KeychainHelper.get(service: keyService, account: connectionID.uuidString)
    }

    /// #375: like `key(for:)` but distinguishes a genuine Keychain read ERROR
    /// (`.failure`) — e.g. the device is still locked before first unlock, so the
    /// `AfterFirstUnlockThisDeviceOnly` item is unreadable — from a key that is
    /// genuinely absent (`.success(nil)`). `ConnectionStore.load` uses this to
    /// know it must re-hydrate on the next foreground rather than caching "".
    static func keyResult(for connectionID: UUID) -> Result<String?, KeychainError> {
        KeychainHelper.getResult(service: keyService, account: connectionID.uuidString)
    }

    // MARK: SOCKS5 password

    static func setSocksPass(connectionID: UUID, pass: String) {
        KeychainHelper.set(pass, service: socksPassService, account: connectionID.uuidString)
    }

    static func socksPass(for connectionID: UUID) -> String? {
        KeychainHelper.get(service: socksPassService, account: connectionID.uuidString)
    }

    // MARK: wbstream token (#436)

    static func setWBToken(connectionID: UUID, token: String) {
        KeychainHelper.set(token, service: wbTokenService, account: connectionID.uuidString)
    }

    static func wbToken(for connectionID: UUID) -> String? {
        KeychainHelper.get(service: wbTokenService, account: connectionID.uuidString)
    }

    // MARK: Removal

    static func remove(connectionID: UUID) {
        KeychainHelper.delete(service: keyService,       account: connectionID.uuidString)
        KeychainHelper.delete(service: socksPassService, account: connectionID.uuidString)
        KeychainHelper.delete(service: wbTokenService,   account: connectionID.uuidString)   // #436
    }
}
