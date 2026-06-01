import Foundation

// MARK: - ConnectionRecord
//
// Protocol-agnostic wrapper around a saved server. Holds the fields that
// every protocol needs (id, user-given name, group) and delegates the
// protocol-specific bits to `details`.
//
// Adding a new protocol (e.g. vless, xray-reality, awg 2.0, xhttp):
//   1. Create a new file `VlessConnection.swift` with the params struct
//   2. Add a case to `ConnectionDetails` below
//   3. Add a case to `ProtocolType`
//   4. Implement the corresponding tunnel manager / editor view
//
// Why an enum (not a protocol with type erasure)?
//  - Codable auto-synthesis works for enums with associated values since
//    Swift 5.5. Type-erased `any ConnectionParams` requires hand-rolled
//    decoding logic for each variant.
//  - Exhaustive `switch` catches missing handlers at compile time when
//    adding new protocols. With protocols you'd discover gaps at runtime.

enum ProtocolType: String, Codable, CaseIterable, Identifiable {
    case olcrtc
    // future: case vless, xray, reality, rprxVision, awg2, xhttp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .olcrtc: return "olcrtc"
        }
    }
}

enum ConnectionDetails: Codable, Equatable, Sendable {
    case olcrtc(OlcrtcConnection)

    var protocolType: ProtocolType {
        switch self {
        case .olcrtc: return .olcrtc
        }
    }

    /// Carrier/server descriptor used for the secondary line in the UI.
    /// Format: "<protocol> · <protocol-specific descriptors>".
    var subtitle: String {
        switch self {
        case .olcrtc(let p): return "\(ProtocolType.olcrtc.label) · \(p.carrier) · \(p.transport)"
        }
    }

    /// Short readable identifier used when the user did not set a name.
    var fallbackName: String {
        switch self {
        case .olcrtc(let p): return p.fallbackName
        }
    }
}

struct ConnectionRecord: Identifiable, Codable, Equatable {
    var id        = UUID()
    var name      : String
    var groupName : String = "Servers" // canonical default; users can rename
    var details   : ConnectionDetails

    var protocolType: ProtocolType { details.protocolType }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? details.fallbackName : trimmed
    }

    var subtitle: String { details.subtitle }
}
