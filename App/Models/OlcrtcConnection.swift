import Foundation

// MARK: - OlcrtcConnection (protocol-specific params)
//
// Pure olcrtc parameters — no name, no group, no id. Those live on
// the wrapping ConnectionRecord. This struct mirrors the fields used by
// MobileStart in olcrtc-upstream/mobile/mobile.go.
//
// Mapping to the URI format from docs/uri.md:
//   olcrtc://<carrier>?<transport>[vp8-fps=X,vp8-batch=Y]@<roomID>#<key>%<clientID>$<mimo>
//
// vp8FPS / vp8BatchSize are per-connection overrides. nil = use the global
// values from SettingsStore. When a URI contains inline params (the [...]
// block), OlcrtcURI.parse() populates these fields so the import carries
// the sender's tuning without touching the user's global defaults.
//
// socksUser / socksPass are SOCKS5 auth credentials for the local proxy
// listener. Empty = no auth (default for our servers). socksPass is never
// written to UserDefaults — it lives in Keychain via ConnectionSecretStore.

struct OlcrtcConnection: Codable, Equatable {
    var carrier     : String
    var transport   : String
    var roomID      : String
    var key         : String
    var clientID    : String
    var vp8FPS      : Int?   = nil
    var vp8BatchSize: Int?   = nil
    var socksUser   : String = ""
    var socksPass   : String = ""

    // SEI channel parameters — only sent to the server when transport == "seichannel",
    // but stored unconditionally so switching transport doesn't lose the values.
    var seiFPS  : Int = 30
    var seiBatch: Int = 10
    var seiFrag : Int = 1200
    var seiACK  : Int = 1

    var fallbackName: String {
        let shortRoom = roomID.count > 12 ? String(roomID.prefix(8)) + "…" : roomID
        return "\(carrier)/\(shortRoom)"
    }

    init(carrier: String, transport: String, roomID: String, key: String, clientID: String,
         vp8FPS: Int? = nil, vp8BatchSize: Int? = nil,
         socksUser: String = "", socksPass: String = "",
         seiFPS: Int = 30, seiBatch: Int = 10, seiFrag: Int = 1200, seiACK: Int = 1) {
        self.carrier      = carrier
        self.transport    = transport
        self.roomID       = roomID
        self.key          = key
        self.clientID     = clientID
        self.vp8FPS       = vp8FPS
        self.vp8BatchSize = vp8BatchSize
        self.socksUser    = socksUser
        self.socksPass    = socksPass
        self.seiFPS       = seiFPS
        self.seiBatch     = seiBatch
        self.seiFrag      = seiFrag
        self.seiACK       = seiACK
    }

    // #401: the OlcrtcURI.Parsed → OlcrtcConnection mapping (carrying the URI's
    // vp8FPS/vp8BatchSize as-is and defaulting the sei params 30/10/1200/1 when a
    // key was absent) was hand-inlined at ~5 call sites — the import paths in
    // App.swift, the install / recover / rotate-key paths in ServersView. The
    // sei `?? 30/10/1200/1` defaults now live HERE, in one place. `clientID`
    // overrides the parsed value when non-nil (the recover path forces "default",
    // since a recovered server.yaml has no client segment).
    init(from parsed: OlcrtcURI.Parsed, clientID: String? = nil,
         socksUser: String = "", socksPass: String = "") {
        self.init(
            carrier:      parsed.carrier,
            transport:    parsed.transport,
            roomID:       parsed.roomID,
            key:          parsed.key,
            clientID:     clientID ?? parsed.clientID,
            vp8FPS:       parsed.vp8FPS,
            vp8BatchSize: parsed.vp8BatchSize,
            socksUser:    socksUser,
            socksPass:    socksPass,
            seiFPS:       parsed.seiFPS   ?? 30,
            seiBatch:     parsed.seiBatch ?? 10,
            seiFrag:      parsed.seiFrag  ?? 1200,
            seiACK:       parsed.seiACK   ?? 1)
    }

    // MARK: - Codable

    // socksPass and key are intentionally excluded — they are stored in Keychain
    // via ConnectionSecretStore and must never be serialised to UserDefaults/JSON.
    private enum CodingKeys: String, CodingKey {
        case carrier, transport, roomID, clientID
        case vp8FPS, vp8BatchSize, seiFPS, seiBatch, seiFrag, seiACK
        case socksUser
        // socksPass and key are intentionally excluded — stored in Keychain via ConnectionSecretStore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        carrier      = try c.decode(String.self, forKey: .carrier)
        transport    = try c.decode(String.self, forKey: .transport)
        roomID       = try c.decode(String.self, forKey: .roomID)
        clientID     = try c.decode(String.self, forKey: .clientID)
        vp8FPS       = try c.decodeIfPresent(Int.self,    forKey: .vp8FPS)
        vp8BatchSize = try c.decodeIfPresent(Int.self,    forKey: .vp8BatchSize)
        socksUser    = try c.decodeIfPresent(String.self, forKey: .socksUser) ?? ""
        seiFPS       = try c.decodeIfPresent(Int.self,    forKey: .seiFPS)   ?? 30
        seiBatch     = try c.decodeIfPresent(Int.self,    forKey: .seiBatch) ?? 10
        seiFrag      = try c.decodeIfPresent(Int.self,    forKey: .seiFrag)  ?? 1200
        seiACK       = try c.decodeIfPresent(Int.self,    forKey: .seiACK)   ?? 1
        // socksPass and key are never decoded from persistent storage;
        // callers must restore them from ConnectionSecretStore after decoding.
        socksPass = ""
        key       = ""
    }
}
