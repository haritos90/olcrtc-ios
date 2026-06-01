import Foundation

// MARK: - ServerHost (model)
//
// Represents an SSH-reachable VPS where we can install / uninstall olcrtc.
// Pure data — no logic, no persistence. The Store and the Keychain glue
// live in `ServerHostStore.swift` and `KeychainHelper.swift`.
//
// Password is intentionally NOT a field here — it goes through Keychain,
// keyed by `id.uuidString`. Codable-encoded JSON of this struct is safe
// to drop into UserDefaults / backups.

struct ServerHost: Identifiable, Codable, Equatable {
    var id       = UUID()
    var label    : String
    var host     : String           // IP or DNS name
    var port     : Int = 22
    var username : String = "root"

    /// Container name returned by the install script. Stored so uninstall
    /// can stop just our container instead of `podman stop $(podman ps -aq)`.
    var lastContainerName: String?

    /// Optional link to the ConnectionRecord created by the last successful
    /// install on this host. Used by the UI to surface "this VPS produced
    /// this connection" in the host card.
    var lastConnectionID : UUID?
}
