import Foundation

// MARK: - OlcrtcSubscription (#111)
//
// Client-side subscription support. A subscription is a plain-text file
// hosted over HTTPS whose format is specified upstream in
// `olcrtc-upstream/docs/sub.md`:
//
//   #key: value      — global subscription fields (name, update, refresh, …)
//   olcrtc://…       — one server per line (docs/uri.md format)
//   ##key: value     — fields of the nearest *preceding* server line
//                      (name, color, icon, used, available, ip, comment)
//
// The app reaches that file through an `olcrtc-sub://` link (registered as
// a URL scheme alongside `olcrtc`): the scheme is swapped to `https`, the
// rest of the URL (host, port, path, query) passes through unchanged.
// Upstream only specifies the *payload* format — the `olcrtc-sub://` link
// convention is defined by olcrtc-ios in docs/uri.md.
//
// Parsing is tolerant by design (the spec allows blank lines and clients
// must ignore fields they don't render): unknown `#`/`##` keys and stray
// text are skipped, and an `olcrtc://` line that fails to parse only bumps
// `skippedURIs` instead of failing the whole import. Of the metadata, only
// the names are consumed today — `#name` becomes the group of the imported
// records, `##name` the record name; the UI/quota fields (color, icon,
// used, available, ip, comment) and `#refresh` auto-update are not
// surfaced yet.

struct OlcrtcSubscription {

    /// One `olcrtc://` server line plus its `##` fields.
    struct Entry {
        let parsed: OlcrtcURI.Parsed
        var name: String?            // ##name

        /// Record name for the import — same fallback chain the manual URI
        /// import in AddConnectionView uses (mimo, then carrier·transport).
        var recordName: String {
            if let n = name, !n.isEmpty { return n }
            return parsed.mimo.isEmpty
                ? "\(parsed.carrier) · \(parsed.transport)"
                : parsed.mimo
        }
    }

    var name: String?                // global #name
    var entries: [Entry] = []
    var skippedURIs = 0              // olcrtc:// lines that failed to parse

    enum SubError: LocalizedError {
        case invalidSubURL           // not olcrtc-sub:// or no host
        case emptySubscription       // fetched fine, but no usable server lines

        var errorDescription: String? {
            switch self {
            case .invalidSubURL:     return L10n.subInvalidLink.localized()
            case .emptySubscription: return L10n.subEmptyList.localized()
            }
        }
    }

    // MARK: olcrtc-sub:// → https:// mapping

    /// Maps an incoming `olcrtc-sub://host[:port]/path[?query]` link to the
    /// HTTPS URL the subscription file is fetched from. Only the scheme
    /// changes; HTTPS is not optional (no `http` opt-out — ATS would block
    /// it anyway and the URI carries the encryption keys).
    static func httpsURL(from url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "olcrtc-sub",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host, !host.isEmpty else {
            throw SubError.invalidSubURL
        }
        comps.scheme = "https"
        guard let https = comps.url else { throw SubError.invalidSubURL }
        return https
    }

    // MARK: Payload parser (upstream sub.md)

    /// Parses a subscription body. Never throws — an unusable body simply
    /// yields zero entries (the caller decides that's `emptySubscription`).
    static func parse(_ body: String) -> OlcrtcSubscription {
        var sub = OlcrtcSubscription()
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Order matters: `##` (server field) before `#` (global field).
            if line.hasPrefix("##") {
                guard let (key, value) = field(of: line.dropFirst(2)),
                      !sub.entries.isEmpty else { continue }
                if key == "name" { sub.entries[sub.entries.count - 1].name = value }
                // color/icon/used/available/ip/comment: accepted, not rendered yet
            } else if line.hasPrefix("#") {
                guard let (key, value) = field(of: line.dropFirst(1)) else { continue }
                if key == "name" { sub.name = value }
                // update/refresh/color/icon/used/available: accepted, not rendered yet
            } else if line.hasPrefix("olcrtc://") {
                if let parsed = try? OlcrtcURI.parse(line) {
                    sub.entries.append(Entry(parsed: parsed, name: nil))
                } else {
                    sub.skippedURIs += 1
                }
            }
            // anything else: stray text, ignored (tolerant per spec)
        }
        return sub
    }

    /// Splits `key: value` (after the `#`/`##` prefix is stripped).
    private static func field(of s: Substring) -> (key: String, value: String)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let key   = s[s.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }
}
