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
        // #355: seichannel payload params (sei.* in docs/uri.md). nil = not in
        // the URI → the import falls back to OlcrtcConnection's defaults. These
        // were previously discarded, and a sei URI's fps/batch wrongly landed in
        // the vp8 fields; now the payload is routed by transport.
        var seiFPS      : Int?
        var seiBatch    : Int?
        var seiFrag     : Int?
        var seiACK      : Int?
    }

    enum ParseError: LocalizedError {
        case invalidScheme
        case missingField(String)
        case mixedBrackets

        var errorDescription: String? {
            switch self {
            case .invalidScheme:       return L10n.uriErrorInvalidScheme.localized()
            case .missingField(let f): return L10n.uriErrorMissingField_fmt.formatted(f)
            // #355 (audit S1): was a hardcoded English literal while its siblings
            // use L10n; route it through the table too.
            case .mixedBrackets:       return L10n.uriErrorMixedBrackets.localized()
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
        } else if p.transport == "seichannel" {
            // #355: emit the sei payload (sei.* keys from docs/uri.md, client
            // [k=v,…] form). seiFPS/seiBatch/seiFrag/seiACK are non-optional on
            // OlcrtcConnection (defaults 30/10/1200/1), so they round-trip back
            // into the sei fields on parse instead of being dropped.
            transportStr += "[fps=\(p.seiFPS),batch=\(p.seiBatch),frag=\(p.seiFrag),ack-ms=\(p.seiACK)]"
        }
        let clientPart = p.clientID == "default" ? "" : "%\(p.clientID)"
        let mimoPart   = mimo.isEmpty ? "" : "$\(mimo)"
        return "olcrtc://\(p.carrier)?\(transportStr)@\(p.roomID)#\(p.key)\(clientPart)\(mimoPart)"
    }

    // MARK: Parse

    /// Parses an `olcrtc://` URI into its constituent fields.
    ///
    /// #398: percent-decode normalization lives HERE now (it used to be a local
    /// fallback only in `handleConnectionURL`, so paste/QR/subscription-body
    /// callers normalized inconsistently). The OS percent-encodes the payload
    /// delimiters (`[ ] , < > &`) when forming a URL from a deep link/QR, which
    /// makes a strict parse either fail OR "succeed" while swallowing the encoded
    /// payload into the transport name — so a raw-then-decoded fallback keyed on
    /// failure alone isn't enough. Order: raw first; if it leaves a `%` in the
    /// transport (a valid transport never contains one) or fails, restore just
    /// the payload delimiters and retry; finally fall back to a full decode for a
    /// wholly percent-encoded URL, else surface the strict diagnostic.
    static func parse(_ raw: String) throws -> Parsed {
        // #398: a valid transport identifier never contains '%'; if a successful
        // raw parse leaves one there, the payload delimiters were percent-encoded
        // and got folded into the transport — so this raw parse isn't trustworthy.
        if let parsed = try? parseStrict(raw), !parsed.transport.contains("%") {
            return parsed
        }
        // #398: opportunistically restore ONLY the payload delimiters the OS
        // escapes, leaving any legitimately-encoded octet elsewhere (e.g. a
        // roomID's %20) intact, then retry.
        let restored = decodingPayloadDelimiters(raw)
        if restored != raw, let parsed = try? parseStrict(restored) {
            return parsed
        }
        // #398 was: the only fallback. A wholly percent-encoded URL escapes the
        // structural delimiters (? @ #) too, so fall back to a full decode; if
        // nothing decodes, surface parseStrict's real diagnostic for a bad URI.
        if let decoded = raw.removingPercentEncoding, decoded != raw {
            return try parseStrict(decoded)
        }
        return try parseStrict(raw)
    }

    /// #398: percent-decodes ONLY the olcrtc payload delimiters (`[ ] , < > &`)
    /// the OS escapes when forming a deep-link/QR URL. Unlike a blanket
    /// `removingPercentEncoding`, it leaves every other escape (e.g. a roomID's
    /// `%20`) untouched, so it can't corrupt a field that legitimately carries one.
    private static func decodingPayloadDelimiters(_ s: String) -> String {
        var out = s
        for (enc, dec) in [("%5B", "["), ("%5D", "]"), ("%2C", ","),
                           ("%3C", "<"), ("%3E", ">"), ("%26", "&")] {
            out = out.replacingOccurrences(of: enc, with: dec, options: [.caseInsensitive])
        }
        return out
    }

    /// The exact field-by-field parse, with no percent-decode normalization
    /// (that lives in `parse`, #398).
    private static func parseStrict(_ raw: String) throws -> Parsed {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("olcrtc://") else { throw ParseError.invalidScheme }

        let (carrier,  r1) = try extractCarrier(from:   String(s.dropFirst("olcrtc://".count)))
        // #355: keep the raw payload; route its keys by transport below (vp8
        // params for vp8channel, sei params for seichannel).
        let (transport, payload, r2) = try extractTransport(from: r1)
        let (roomID,   r3) = try extractRoomID(from:   r2)
        let (key, clientID, mimo)       = extractTail(from: r3)

        guard !carrier.isEmpty   else { throw ParseError.missingField("carrier") }
        guard !transport.isEmpty else { throw ParseError.missingField("transport") }
        guard !roomID.isEmpty    else { throw ParseError.missingField("roomID") }
        guard !key.isEmpty       else { throw ParseError.missingField("key") }

        let p = parsePayload(payload, transport: transport)   // #355: transport-routed
        return Parsed(carrier: carrier, transport: transport,
                      roomID: roomID, key: key,
                      clientID: clientID, mimo: mimo,
                      vp8FPS: p.vp8FPS, vp8BatchSize: p.vp8Batch,
                      seiFPS: p.seiFPS, seiBatch: p.seiBatch,
                      seiFrag: p.seiFrag, seiACK: p.seiACK)
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
    /// Returns (transport, raw-payload, rest-after-@). The payload is left
    /// unparsed here so the caller can route its keys by transport (#355).
    /// Throws if `@` is absent.
    private static func extractTransport(
        from s: String
    ) throws -> (transport: String, payload: String, rest: String) {

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
            return (transport, payload, String(s[s.index(after: atIdx)...]))
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
            return (transport, payload, String(s[s.index(after: atIdx)...]))
        }

        // No payload block — plain transport@roomID
        guard let atIdx = s.firstIndex(of: "@") else {
            throw ParseError.missingField("roomID (@)")
        }
        return (String(s[s.startIndex..<atIdx]), "",
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

    /// Parsed payload params, routed by transport. All optional: nil = the key
    /// was absent, so the import keeps the app/connection default.
    private struct Payload {
        var vp8FPS  : Int?
        var vp8Batch: Int?
        var seiFPS  : Int?
        var seiBatch: Int?
        var seiFrag : Int?
        var seiACK  : Int?
    }

    /// Parses `key=value` pairs separated by `,` or `&`, routing keys by
    /// transport (#355): `vp8-fps`/`vp8-batch` belong to vp8channel; sei's
    /// `fps`/`batch`/`frag`/`ack-ms` belong to seichannel (docs/uri.md). Bare
    /// `fps`/`batch` are accepted as vp8 aliases for the non-sei transports so
    /// older vp8 URIs that omitted the `vp8-` prefix still parse.
    /// Unknown keys are silently ignored for forward compatibility.
    private static func parsePayload(_ payload: String, transport: String) -> Payload {
        var p = Payload()
        let isSEI = transport == "seichannel"   // #355
        for pair in payload.split(whereSeparator: { $0 == "," || $0 == "&" }) {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            switch (isSEI, k) {
            case (false, "vp8-fps"), (false, "fps"):     p.vp8FPS   = intOrLog(k, v)
            case (false, "vp8-batch"), (false, "batch"): p.vp8Batch = intOrLog(k, v)
            case (true,  "fps"):                         p.seiFPS   = intOrLog(k, v)
            case (true,  "batch"):                       p.seiBatch = intOrLog(k, v)
            case (true,  "frag"):                        p.seiFrag  = intOrLog(k, v)
            case (true,  "ack-ms"):                      p.seiACK   = intOrLog(k, v)
            default: break
            }
        }
        return p
    }

    /// Parses an Int payload value, logging (not failing) an unparseable one.
    private static func intOrLog(_ k: String, _ v: String) -> Int? {
        if let n = Int(v) { return n }
        Task { @MainActor in
            LogStore.shared.log(.connection,
                "⚠ OlcrtcURI: skipping unparseable '\(k)=\(v)' in payload")
        }
        return nil
    }
}
