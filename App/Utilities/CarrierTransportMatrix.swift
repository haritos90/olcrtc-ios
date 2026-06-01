import SwiftUI

// MARK: - CarrierTransportMatrix
//
// Carrier × Transport compatibility reference, shown in the Servers tab.
// Based on upstream e2e test results and observed behaviour in the field.
// Update the `matrix` dict as new data arrives — see TODO.md for details.
//
// Sources:
//   - wbstream datachannel: was disabled by the carrier at some point
//   - telemost vp8channel: confirmed recommended by OpenWRT panel and plumbicon

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

    static let matrix: [String: [String: Compat]] = [
        "telemost": [
            "datachannel":  .ok,
            "vp8channel":   .recommended,
            "seichannel":   .unknown,
            "videochannel": .unknown,
        ],
        "wbstream": [
            "datachannel":  .fail,       // broken since upstream dropped room auto-generation
            "vp8channel":   .ok,
            "seichannel":   .unknown,
            "videochannel": .unknown,
        ],
        "jitsi": [
            "datachannel":  .ok,         // confirmed working (SCTP fallback + RTCP keepalive)
            "vp8channel":   .question,   // marked unstable by upstream e2e
            "seichannel":   .question,   // marked unstable by upstream e2e
            "videochannel": .question,   // needs ffmpeg, unstable
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
                    Text(c)
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
