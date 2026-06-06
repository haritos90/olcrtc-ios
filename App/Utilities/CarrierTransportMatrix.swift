import SwiftUI

// MARK: - CarrierTransportMatrix
//
// Carrier × Transport compatibility reference, shown in the Servers tab.
//
// #284: re-derived from the upstream authoritative matrix in
// `olcrtc-upstream/docs/settings.md` ("Матрица совместимости", from the E2E
// suite). Legend mapping: `+` (pass) → .ok, the per-carrier best/default → .recommended,
// `~` (unstable, may work) → .question, `-` (fail / unsupported) → .fail.
//
//   | transport    | telemost | wbstream | jitsi |
//   | datachannel  |    -     |    ~     |   +   |
//   | vp8channel   |    +     |    +     |   ~   |
//   | seichannel   |    -     |    +     |   ~   |
//   | videochannel |    +     |    +     |   ~   |
//
// Upstream notes: Telemost dropped DataChannel (fail) and never supported sei;
// videochannel works but is slow. WBStream runs everything except datachannel
// (guest tokens set canPublishData=false → unstable). Jitsi's datachannel is the
// one stable, recommended combo; its video transports flap (Jicofo routing).

/// Compatibility level between a carrier and a transport, based on observed test results.
enum Compat {
    case recommended   // ★ confirmed working and preferred
    case ok            // ✓ confirmed working
    case question      // ? uncertain / intermittent
    case fail          // ✗ confirmed broken
    case unknown       // — no data

    var symbol: String {
        switch self {
        case .recommended: return "★"
        case .ok:          return "✓"
        case .question:    return "?"
        case .fail:        return "✗"
        case .unknown:     return "—"
        }
    }

    var color: Color {
        switch self {
        case .recommended, .ok: return .green
        case .question:         return .orange
        case .fail:             return .red
        case .unknown:          return Color(.systemGray)
        }
    }
}

enum CarrierTransportMatrix {
    static let carriers:   [String] = ["telemost", "wbstream", "jitsi"]
    static let transports: [String] = ["datachannel", "vp8channel", "seichannel", "videochannel"]

    /// Friendly, localised display names for the raw carrier / transport IDs
    /// (#283) — the pickers and matrix used to show bare IDs (`telemost`,
    /// `vp8channel`). The selection *value* stays the raw ID; only the label
    /// changes. Unknown IDs pass through so a future backend still renders.
    static func carrierLabel(_ id: String) -> String {
        switch id {
        case "telemost": return L10n.carrierTelemost.localized()
        case "wbstream": return L10n.carrierWbstream.localized()
        case "jitsi":    return L10n.carrierJitsi.localized()
        default:         return id
        }
    }
    static func transportLabel(_ id: String) -> String {
        switch id {
        case "datachannel":  return L10n.transportDatachannel.localized()
        case "vp8channel":   return L10n.transportVp8channel.localized()
        case "seichannel":   return L10n.transportSeichannel.localized()
        case "videochannel": return L10n.transportVideochannel.localized()
        default:             return id
        }
    }

    static let matrix: [String: [String: Compat]] = [
        "telemost": [
            "datachannel":  .fail,         // DataChannel removed from Telemost (upstream)
            "vp8channel":   .recommended,  // only stable transport for telemost; the default
            "seichannel":   .fail,         // not supported
            "videochannel": .ok,           // works but slow
        ],
        "wbstream": [
            "datachannel":  .question,     // guest tokens canPublishData=false → unstable
            "vp8channel":   .recommended,  // stable for commercial flows; the default
            "seichannel":   .ok,
            "videochannel": .ok,
        ],
        "jitsi": [
            "datachannel":  .recommended,  // the one stable combo upstream recommends everywhere
            "vp8channel":   .question,     // Jicofo video routing flaps (unstable)
            "seichannel":   .question,     // SEI passenger frames flap on self-hosted Jicofo
            "videochannel": .question,     // needs extra Jingle steps; unstable
        ],
    ]

    static func compat(carrier: String, transport: String) -> Compat {
        matrix[carrier]?[transport] ?? .unknown
    }

    /// Best transport to pre-select when user picks a carrier.
    static func defaultTransport(for carrier: String) -> String {
        switch carrier {
        case "jitsi":  return "datachannel"
        default:       return "vp8channel"
        }
    }

    /// Carriers that auto-generate a room ID when the user leaves the field
    /// empty. For every other carrier the room ID is mandatory and the
    /// install will fail server-side with "OLCRTC_ROOM_ID is required".
    ///
    /// Currently empty: every carrier requires an explicit room ID in the iOS UI.
    /// `scripts/srv.sh` *can* auto-generate a Jitsi room URL when OLCRTC_ROOM_ID
    /// is empty (#226), but the app keeps the field required for jitsi too,
    /// because the lightweight reconfigure path (`SSHRunner.reconfigureScript`)
    /// writes `room.id` verbatim and has no auto-gen — an empty room there would
    /// produce a broken config. Making the field optional for jitsi is deferred
    /// until reconfigure can auto-generate as well; if you add `"jitsi"` here,
    /// fix reconfigure in the same change.
    static let autoGeneratesRoomID: Set<String> = []

    /// Inverse of `autoGeneratesRoomID`. Unknown carriers default to
    /// `true` (Set.contains returns false), matching the server's
    /// "fail closed" behaviour.
    static func requiresRoomID(carrier: String) -> Bool {
        !autoGeneratesRoomID.contains(carrier)
    }
}

// MARK: - MatrixView

struct MatrixView: View {
    var highlightCarrier:   String? = nil
    var highlightTransport: String? = nil

    private func shortT(_ t: String) -> String {
        switch t {
        case "datachannel":  return "data"
        case "vp8channel":   return "vp8"
        case "seichannel":   return "sei"
        case "videochannel": return "video"
        default:             return t
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header
            HStack(spacing: 0) {
                Text("").frame(width: 72, alignment: .leading)
                ForEach(CarrierTransportMatrix.transports, id: \.self) { t in
                    Text(shortT(t))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            // Rows
            ForEach(CarrierTransportMatrix.carriers, id: \.self) { c in
                HStack(spacing: 0) {
                    Text(CarrierTransportMatrix.carrierLabel(c))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 72, alignment: .leading)
                        .foregroundStyle(c == highlightCarrier ? .primary : .secondary)
                        .fontWeight(c == highlightCarrier ? .semibold : .regular)
                    ForEach(CarrierTransportMatrix.transports, id: \.self) { t in
                        let cp = CarrierTransportMatrix.compat(carrier: c, transport: t)
                        let isHighlighted = c == highlightCarrier && t == highlightTransport
                        Text(cp.symbol)
                            .font(.system(isHighlighted ? .caption : .caption2,
                                          design: .monospaced))
                            .foregroundStyle(cp.color)
                            .fontWeight(isHighlighted ? .bold : .regular)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            Divider()
            // Legend
            HStack(spacing: 10) {
                ForEach([
                    ("★", Color.green,          L10n.matrixStatusRecommended.localized()),
                    ("✓", Color.green,          L10n.matrixStatusOK.localized()),
                    ("?", Color.orange,         L10n.matrixStatusQuestion.localized()),
                    ("✗", Color.red,            L10n.matrixStatusFail.localized()),
                    ("—", Color(.systemGray),   L10n.matrixStatusUnknown.localized()),
                ], id: \.0) { sym, col, label in
                    HStack(spacing: 2) {
                        Text(sym).foregroundStyle(col).fontWeight(.semibold)
                        Text(label).foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
