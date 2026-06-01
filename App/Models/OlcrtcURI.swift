import Foundation

// MARK: - OlcrtcURI
//
// Parser and encoder for the olcrtc:// URI scheme:
//
//   olcrtc://<carrier>?<transport>[<params>]@<roomID>#<key>[%<clientID>][$<mimo>]
//
// Transport payload block comes in two styles:
//
//   [vp8-fps=60,vp8-batch=8]  — "client" format (comma-separated, square brackets)
//                                Emitted by OlcrtcURI.encode() — used in QR codes,
//                                clipboard, and connection imports on the iOS side.
//
//   <vp8-fps=60&vp8-batch=8>  — "server-script" format (ampersand-separated, angle brackets)
//                                Emitted by srv.sh in the OLCRTC_URI= output line.
//
// Both originate from the same olcrtc system; we store connections from either
// source, so the parser must handle both. The encoder always writes client format.
//
// %clientID is optional (removed from upstream URI format in olcrtc @ 6ba8fcd).
// When absent the clientID defaults to "default". The encoder omits %default.

struct OlcrtcURI {
    struct Parsed {
        var carrier     : String
        var transport   : String
        var roomID      : String
        var key         : String
        var clientID    : String
        var mimo        : String   // server-side: "sub_configname" / OLCRTC_CONFIG_NAME (scripts/srv.sh)
        var vp8FPS      : Int?
        var vp8BatchSize: Int?
    }

    enum ParseError: LocalizedError {
        case invalidScheme
        case missingField(String)
        case mixedBrackets

        var errorDescription: String? {
            switch self {
            case .invalidScheme:       return L10n.uriErrorInvalidScheme.localized()
            case .missingField(let f): return L10n.uriErrorMissingField_fmt.formatted(f)
            case .mixedBrackets:       return "URI payload brackets are mismatched (expected [...] or <...>)"
            }
        }
    }

    // MARK: Encode

    /// Encodes a connection to an `olcrtc://` URI (client format).
    static func encode(_ p: OlcrtcConnection, mimo: String = "") -> String {
        var transportStr = p.transport
        if p.transport == "vp8channel" {
            let fps   = p.vp8FPS       ?? SettingsStore.shared.vp8FPS
            let batch = p.vp8BatchSize ?? SettingsStore.shared.vp8BatchSize
            transportStr += "[vp8-fps=\(fps),vp8-batch=\(batch)]"
        }
        let clientPart = p.clientID == "default" ? "" : "%\(p.clientID)"
        let mimoPart   = mimo.isEmpty ? "" : "$\(mimo)"
        return "olcrtc://\(p.carrier)?\(transportStr)@\(p.roomID)#\(p.key)\(clientPart)\(mimoPart)"
    }

    // MARK: Parse

    /// Parses an `olcrtc://` URI into its constituent fields.
    static func parse(_ raw: String) throws -> Parsed {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("olcrtc://") else { throw ParseError.invalidScheme }

        let (carrier,  r1) = try extractCarrier(from:   String(s.dropFirst("olcrtc://".count)))
        let (transport, fps, batch, r2) = try extractTransport(from: r1)
        let (roomID,   r3) = try extractRoomID(from:   r2)
        let (key, clientID, mimo)       = extractTail(from: r3)

        guard !carrier.isEmpty   else { throw ParseError.missingField("carrier") }
        guard !transport.isEmpty else { throw ParseError.missingField("transport") }
        guard !roomID.isEmpty    else { throw ParseError.missingField("roomID") }
        guard !key.isEmpty       else { throw ParseError.missingField("key") }

        return Parsed(carrier: carrier, transport: transport,
                      roomID: roomID, key: key,
                      clientID: clientID, mimo: mimo,
                      vp8FPS: fps, vp8BatchSize: batch)
    }

    // MARK: Parse helpers

    /// Splits `<carrier>?<rest>` → (carrier, rest). Throws if `?` is absent.
    private static func extractCarrier(from s: String) throws -> (String, String) {
        guard let idx = s.firstIndex(of: "?") else {
            throw ParseError.missingField("transport (?)")
        }
        return (String(s[s.startIndex..<idx]),
                String(s[s.index(after: idx)...]))
    }

    /// Splits `<transport>[payload]@<rest>` or `<transport>@<rest>`.
    ///
    /// Handles both payload styles (see module-level comment):
    ///   • `[...]`  — client format (comma-separated key=value pairs)
    ///   • `<...>`  — server-script format (ampersand-separated)
    ///
    /// Returns (transport, vp8FPS, vp8Batch, rest-after-@). Throws if `@` is absent.
    private static func extractTransport(
        from s: String
    ) throws -> (transport: String, fps: Int?, batch: Int?, rest: String) {

        // Client format: transport[vp8-fps=60,vp8-batch=8]@roomID
        if let openIdx  = s.firstIndex(of: "["),
           let closeIdx = s.firstIndex(of: "]"),
           closeIdx > openIdx,
           let atIdx = s[s.index(after: closeIdx)...].firstIndex(of: "@") {
            // Guard against mixed brackets: no `>` must appear before the closing `]`
            if let wrongClose = s[s.index(after: openIdx)...].firstIndex(of: ">"),
               wrongClose < closeIdx {
                throw ParseError.mixedBrackets
            }
            let transport = String(s[s.startIndex..<openIdx])
            let payload   = String(s[s.index(after: openIdx)..<closeIdx])
            let (fps, batch) = parsePayload(payload)
            return (transport, fps, batch, String(s[s.index(after: atIdx)...]))
        }

        // Server-script format: transport<vp8-fps=60&vp8-batch=8>@roomID
        if let openIdx  = s.firstIndex(of: "<"),
           let closeIdx = s.firstIndex(of: ">"),
           closeIdx > openIdx,
           let atIdx = s[s.index(after: closeIdx)...].firstIndex(of: "@") {
            // Guard against mixed brackets: no `]` must appear before the closing `>`
            if let wrongClose = s[s.index(after: openIdx)...].firstIndex(of: "]"),
               wrongClose < closeIdx {
                throw ParseError.mixedBrackets
            }
            let transport = String(s[s.startIndex..<openIdx])
            let payload   = String(s[s.index(after: openIdx)..<closeIdx])
            let (fps, batch) = parsePayload(payload)
            return (transport, fps, batch, String(s[s.index(after: atIdx)...]))
        }

        // No payload block — plain transport@roomID
        guard let atIdx = s.firstIndex(of: "@") else {
            throw ParseError.missingField("roomID (@)")
        }
        return (String(s[s.startIndex..<atIdx]), nil, nil,
                String(s[s.index(after: atIdx)...]))
    }

    /// Splits `<roomID>#<rest>` → (roomID, rest). Throws if `#` is absent.
    private static func extractRoomID(from s: String) throws -> (String, String) {
        guard let idx = s.firstIndex(of: "#") else {
            throw ParseError.missingField("key (#)")
        }
        return (String(s[s.startIndex..<idx]),
                String(s[s.index(after: idx)...]))
    }

    /// Splits `<key>[%clientID][$mimo]` into its three parts.
    /// clientID defaults to "default" when absent (upstream change @ 6ba8fcd).
    private static func extractTail(
        from s: String
    ) -> (key: String, clientID: String, mimo: String) {
        if let pctIdx = s.firstIndex(of: "%") {
            let key  = String(s[s.startIndex..<pctIdx])
            let rest = String(s[s.index(after: pctIdx)...])
            if let dollarIdx = rest.firstIndex(of: "$") {
                return (key, String(rest[rest.startIndex..<dollarIdx]),
                        String(rest[rest.index(after: dollarIdx)...]))
            }
            return (key, rest, "")
        }
        if let dollarIdx = s.firstIndex(of: "$") {
            return (String(s[s.startIndex..<dollarIdx]), "default",
                    String(s[s.index(after: dollarIdx)...]))
        }
        return (s, "default", "")
    }

    // MARK: Payload key=value parser

    /// Parses `key=value` pairs separated by `,` or `&`.
    /// Unknown keys are silently ignored for forward compatibility.
    private static func parsePayload(_ payload: String) -> (fps: Int?, batch: Int?) {
        var fps: Int?
        var batch: Int?
        for pair in payload.split(whereSeparator: { $0 == "," || $0 == "&" }) {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            switch k {
            case "vp8-fps", "fps":
                if let n = Int(v) {
                    fps = n
                } else {
                    Task { @MainActor in
                        LogStore.shared.log(.connection,
                            "⚠ OlcrtcURI: skipping unparseable '\(k)=\(v)' in payload")
                    }
                }
            case "vp8-batch", "batch":
                if let n = Int(v) {
                    batch = n
                } else {
                    Task { @MainActor in
                        LogStore.shared.log(.connection,
                            "⚠ OlcrtcURI: skipping unparseable '\(k)=\(v)' in payload")
                    }
                }
            default: break
            }
        }
        return (fps, batch)
    }
}
