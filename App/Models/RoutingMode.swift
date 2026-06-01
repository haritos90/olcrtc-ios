import Foundation

// MARK: - RoutingMode
//
// Defines how traffic from local apps is routed once the tunnel is up.
//
// Today only `.allTunnel` exists. Planned future modes:
//
//   .allDirect — global kill switch: bypass the tunnel even when connected.
//                Useful for "tunnel off but stay connected" scenarios.
//
//   .rules     — per-host / per-domain rules loaded from a config file
//                (.conf / .yaml). Matches Shadowrocket's "Config" tab.
//
//   .scene     — geo-aware profiles ("Home Wi-Fi → direct, Cellular → tunnel"),
//                like Shadowrocket's "Scene" feature. Requires location and
//                network monitoring entitlements.
//
// Stored in UserDefaults via @AppStorage in ConnectionsView. When more
// fields are added we'll promote this to a proper AppSettings store.

enum RoutingMode: String, CaseIterable, Identifiable {
    case allTunnel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTunnel: return L10n.routingAllTunnel.localized()
        }
    }
}
