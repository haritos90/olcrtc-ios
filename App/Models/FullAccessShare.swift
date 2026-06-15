import Foundation

// MARK: - FullAccessShare (#135)
//
// PROPOSED wire format for the opt-in "full access" connection share — the
// co-admin variant that conveys BOTH the connection URI and the VPS SSH
// credentials so the recipient can MANAGE the server (install / reconfigure /
// reboot / uninstall), not merely connect through it.
//
// ⚠️ STATUS: PROPOSAL (#135). This is a new wire format and a security surface;
// the exact framing is an operator decision. The UI, the destructive-style
// warning, and this documented payload are implemented; the byte format below
// is a proposal pending sign-off. Keep `formatVersion` so a future change can
// be detected and migrated/rejected rather than silently misparsed.
//
// FORMAT (#366: use the familiar olcrtc:// scheme, not a new olcrtc-host:// one)
// ------
//   olcrtc://host/v1/<base64url(JSON)>
//
// where JSON is this struct, Codable-encoded. Base64url (no padding) keeps the
// blob URL-safe for the system share sheet / clipboard. It reuses the already-
// registered `olcrtc://` scheme with a distinguishing `host/` authority+path so
// no new URL scheme must be registered and a recipient's handler can still tell
// it apart from a plain connection URI (which is `olcrtc://<carrier>?<transport>@…`
// — it always has a `?` and never a `/v1/` path). The `v1` segment mirrors
// `formatVersion` so a parser can reject an unknown version before decoding. The
// payload carries the connection `uri` (the same `olcrtc://` string the URI-only
// share produces) PLUS the SSH host/port/username/password.
//
// SECURITY
// --------
//   • Opt-in only, behind an explicit destructive-style warning in the UI.
//   • The SSH password is read live from the Keychain (ServerHostStore /
//     KeychainHelper) at share time — never persisted into UserDefaults.
//   • This blob MUST NOT be logged: callers log the *action*, never the payload,
//     and `LogStore.redactSecrets` already scrubs the embedded `olcrtc://#key`.
//     The SSH password has no such on-the-wire redaction, which is exactly why
//     sharing is gated behind the warning — anyone with the link controls the
//     VPS.

struct FullAccessShare: Codable, Equatable {
    /// Bumped if the JSON shape changes; also encoded in the URL authority so a
    /// parser can reject an unknown version before attempting to decode.
    var formatVersion: Int = 1

    /// The same `olcrtc://…` connection string the URI-only share produces —
    /// lets the recipient connect immediately, not just manage the VPS.
    var uri: String

    // SSH access to the VPS (ServerHost fields + the Keychain password).
    var label: String
    var sshHost: String
    var sshPort: Int
    var sshUsername: String
    var sshPassword: String

    // #366 was: scheme = "olcrtc-host". Reuse the registered `olcrtc://` scheme
    // with a `host/` authority so no new URL scheme must be registered; the
    // `host/` prefix is what distinguishes a full-access link from a plain
    // connection URI (`olcrtc://<carrier>?…`).
    static let scheme = "olcrtc"
    static let hostToken = "host"
    static let versionToken = "v1"

    /// The prefix that marks a full-access link: `olcrtc://host/`. A plain
    /// connection URI never starts with this (its authority is a carrier and is
    /// followed by `?`), so the importer uses it to route the link (#366).
    static var linkPrefix: String { "\(scheme)://\(hostToken)/" }

    /// True iff `raw` looks like a full-access link (vs a plain connection URI).
    static func isFullAccessLink(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(linkPrefix)
    }

    /// Encodes to `olcrtc://host/v1/<base64url(JSON)>`. Returns nil only if JSON
    /// encoding fails (it can't for these plain fields), so callers can treat a
    /// nil result as a programmer error rather than a user-facing one.
    func encoded() -> String? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        return "\(Self.linkPrefix)\(Self.versionToken)/\(Self.base64urlEncode(json))"
    }

    /// Parses an `olcrtc-host://v1/…` link back into a payload. Throws on a bad
    /// scheme, an unknown version, or undecodable JSON so an importer can show a
    /// precise reason instead of silently dropping a malformed link.
    enum ParseError: Error, Equatable {
        case invalidScheme
        case unsupportedVersion(String)
        case malformedPayload
    }

    static func parse(_ raw: String) throws -> FullAccessShare {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // #366: a full-access link is `olcrtc://host/v1/<blob>`; a plain
        // connection URI (`olcrtc://<carrier>?…`) lacks the `host/` prefix.
        guard s.hasPrefix(linkPrefix) else { throw ParseError.invalidScheme }
        let afterPrefix = String(s.dropFirst(linkPrefix.count))   // "v1/<blob>"
        guard let slash = afterPrefix.firstIndex(of: "/") else {
            throw ParseError.malformedPayload
        }
        let version = String(afterPrefix[afterPrefix.startIndex..<slash])
        guard version == versionToken else { throw ParseError.unsupportedVersion(version) }
        let blob = String(afterPrefix[afterPrefix.index(after: slash)...])
        guard let data = base64urlDecode(blob),
              let decoded = try? JSONDecoder().decode(FullAccessShare.self, from: data) else {
            throw ParseError.malformedPayload
        }
        return decoded
    }

    // MARK: base64url (no padding) — URL-safe so the blob survives share sheets.

    static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4 for the stdlib decoder.
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        return Data(base64Encoded: b64)
    }
}
