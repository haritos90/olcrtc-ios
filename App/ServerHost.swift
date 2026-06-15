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
    // underscore, and leading/trailing underscores are trimmed.
    // e.g. "TW Moscow #1" -> "TW_Moscow_1".
    // #323: an all-non-ASCII label (e.g. Cyrillic "Москва") used to collapse to
    // the empty string and fall back to the literal "server", so two differently
    // named Cyrillic hosts produced the *same* prefix — they shared one container
    // log file and tripped a false "duplicate name" error on add. Now any label
    // that drops one-or-more non-ASCII characters (or sanitises to empty) gets a
    // short, stable hash of the *original* label appended, so distinct names map
    // to distinct prefixes. The hash is a deterministic FNV-1a (NOT Swift's
    // per-process-randomised `hashValue`) so the same name resolves to the same
    // file across launches.
    // e.g. "Москва" -> "server_feb471b1", "Москва-1" -> "server_925f0bbf".
    var logFilePrefix: String {
        Self.sanitizeLogFilePrefix(label)
    }

    static func sanitizeLogFilePrefix(_ label: String) -> String {
        var out = ""
        var lastWasUnderscore = false
        var droppedNonASCII = false   // #323: any non-ASCII char that was collapsed
        for ch in label {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastWasUnderscore = false
            } else {
                if !ch.isASCII { droppedNonASCII = true }   // #323
                if !lastWasUnderscore && !out.isEmpty {
                    out.append("_")
                    lastWasUnderscore = true
                }
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        // #323: collision-proof the lossy non-ASCII case with a stable suffix.
        // When the sanitised core is empty we keep the "server" base so the
        // filename stays readable, but always disambiguate with the hash.
        if droppedNonASCII || out.isEmpty {
            let base = out.isEmpty ? "server" : out
            return "\(base)_\(stableHash(label))"
        }
        return out
    }

    /// #323: deterministic FNV-1a (32-bit) over the label's UTF-8 bytes, as 8
    /// lowercase hex digits. Process-independent — unlike `String.hashValue`,
    /// which is salted per launch — so a host's container-log filename is stable
    /// across app restarts. Collision risk between two real host names is
    /// negligible at this scale; the goal is only to keep distinct names distinct.
    private static func stableHash(_ s: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }
}
