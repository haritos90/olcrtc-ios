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

    // #295: per-server container logs are stored as `<logFilePrefix>_container.log`.
    // Sanitises `label` into a filesystem-safe prefix: alphanumerics are kept,
    // everything else (spaces, punctuation, non-ASCII) collapses to a single
    // underscore, and leading/trailing underscores are trimmed. Empty/all-symbol
    // labels fall back to "server" so the filename is never empty.
    // e.g. "TW Moscow #1" -> "TW_Moscow_1", "  " -> "server".
    var logFilePrefix: String {
        Self.sanitizeLogFilePrefix(label)
    }

    static func sanitizeLogFilePrefix(_ label: String) -> String {
        var out = ""
        var lastWasUnderscore = false
        for ch in label {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastWasUnderscore = false
            } else if !lastWasUnderscore && !out.isEmpty {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? "server" : out
    }
}
