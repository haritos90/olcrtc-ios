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
        // #363: previously-dropped per-node `##` metadata, now carried through
        // import onto the record so the group/node detail view can render it.
        // All server-provided free text — rendered defensively. Defaulted to nil
        // so the existing `Entry(parsed:name:)` call sites still compile.
        var used     : String? = nil // ##used (e.g. "500mb/10gb")
        var available: String? = nil // ##available
        var ip       : String? = nil // ##ip
        var comment  : String? = nil // ##comment

        /// Record name for the import — same fallback chain the manual URI
        /// import in AddConnectionView uses (mimo, then carrier·transport).
        var recordName: String {
            if let n = name, !n.isEmpty { return n }
            return parsed.mimo.isEmpty
                ? "\(parsed.carrier) · \(parsed.transport)"
                : parsed.mimo
        }

        /// Stable per-node identity for dedup across re-imports (#356). Keyed on
        /// the connection-defining fields only — carrier, transport, room, key,
        /// clientID — so re-editing a node's display name/comment upstream still
        /// maps to the same record. Display metadata (mimo/##name) is excluded.
        var nodeKey: String {
            [parsed.carrier, parsed.transport, parsed.roomID,
             parsed.key, parsed.clientID].joined(separator: "\u{1}")
        }
    }

    var name: String?                // global #name
    var refresh: String?             // global #refresh (e.g. "5s", "10m", "6h", "1d") — #356
    // #363: previously-dropped global `#` metadata, now carried through onto the
    // per-source SubscriptionMeta so the group detail view can render quota.
    var used: String?                // global #used (e.g. "10mb/10gb")
    var available: String?           // global #available
    var entries: [Entry] = []
    var skippedURIs = 0              // olcrtc:// lines that failed to parse

    /// `#refresh` parsed to seconds (#356). Supports the `Ns`/`Nm`/`Nh`/`Nd`
    /// forms from sub.md's recommendations; a bare integer is read as seconds.
    /// nil = no/unparseable `#refresh` (the caller treats that as "never auto-refresh").
    var refreshInterval: TimeInterval? {
        guard let r = refresh?.trimmingCharacters(in: .whitespaces).lowercased(),
              !r.isEmpty else { return nil }
        let unit = r.last!
        let multiplier: TimeInterval
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        case "d": multiplier = 86400
        default:
            // No unit suffix → treat the whole string as seconds.
            return TimeInterval(r).map { max(0, $0) }
        }
        guard let n = Double(r.dropLast()), n >= 0 else { return nil }
        return n * multiplier
    }

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

    // MARK: Paste-and-import detection (#361)

    /// What a pasted blob in the import box resolves to. The paste box accepts
    /// more than `olcrtc-sub://` deep links now: a single connection URI, a remote
    /// subscription URL to fetch, or raw sub.md text to parse directly.
    enum ImportInput: Equatable {
        case connectionURI(String)   // a single olcrtc:// link → single-connection import (#354)
        case subscriptionURL(URL)    // an https:// (or olcrtc-sub://) link → fetch then import
        case subscriptionBody(String) // raw sub.md text (multiple lines / markers) → parse then import
        case unrecognized
    }

    /// Classifies a pasted blob without any network or field side-effects (pure →
    /// tested). Order matters:
    ///   1. a lone `olcrtc://` line → single-connection URI;
    ///   2. an `olcrtc-sub://` or `https://` link → a subscription URL to fetch;
    ///   3. anything that looks like sub.md (an `olcrtc://` line among others, or a
    ///      `#`/`##` marker line) → raw subscription body to parse in place;
    ///   4. otherwise unrecognized.
    /// HTTPS-only for URLs (preserves the ATS / #008–#009 posture): a plain
    /// `http://` link is NOT treated as a subscription URL.
    static func detectImport(_ raw: String) -> ImportInput {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrecognized }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 1. A single olcrtc:// connection link (one line, no sub.md markers).
        if lines.count == 1, let only = lines.first, only.hasPrefix("olcrtc://") {
            return .connectionURI(only)
        }

        // 2. A single subscription link: olcrtc-sub:// (mapped to https) or https://.
        if lines.count == 1, let only = lines.first {
            let lower = only.lowercased()
            if lower.hasPrefix("olcrtc-sub://"), let url = URL(string: only) {
                return .subscriptionURL(url)
            }
            if lower.hasPrefix("https://"), let url = URL(string: only) {
                return .subscriptionURL(url)
            }
        }

        // 3. Raw sub.md body — multiple lines containing olcrtc:// lines and/or
        //    #/## marker lines.
        let looksLikeBody = lines.contains { $0.hasPrefix("olcrtc://") || $0.hasPrefix("#") }
        if looksLikeBody { return .subscriptionBody(trimmed) }

        return .unrecognized
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
                let last = sub.entries.count - 1
                // #363: carry the useful per-node fields onto the entry; color/icon
                // remain accepted-but-unrendered (no Theme-token mapping for arbitrary
                // server-supplied hex/emoji).
                switch key {
                case "name":      sub.entries[last].name      = value
                case "used":      sub.entries[last].used      = value
                case "available": sub.entries[last].available = value
                case "ip":        sub.entries[last].ip        = value
                case "comment":   sub.entries[last].comment   = value
                default: break
                }
            } else if line.hasPrefix("#") {
                guard let (key, value) = field(of: line.dropFirst(1)) else { continue }
                // #363: carry the useful global fields; update/color/icon remain
                // accepted-but-unrendered.
                switch key {
                case "name":      sub.name      = value
                case "refresh":   sub.refresh   = value   // #356: drives the "refresh due" check
                case "used":      sub.used      = value   // #363
                case "available": sub.available = value   // #363
                default: break
                }
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
