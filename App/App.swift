import SwiftUI

// MARK: - App entry
//
// Hosts the root TabView with four tabs:
//   - Connections — server list, global toggle, status, IP/speed test triggers
//   - VPS         — SSH-managed hosts: install / uninstall / reboot olcrtc
//   - Logs        — per-category log browser with copy-to-clipboard
//   - Settings    — port, DNS, font size, vp8 tuning, debug toggle
//
// All @StateObject stores live on MainTabView so they survive tab switches
// and the tunnel can keep running while the user navigates around.
// SettingsStore is the only singleton (state shared between SwiftUI views
// and non-view callers like SOCKSSession), so it's referenced as .shared
// rather than @StateObject.

@main
// #241 was: struct OlcRTCiOSApp — the only identifier using the "OlcRTC" display
// form. Renamed to the Olcrtc* Swift type-prefix convention (OlcrtcConnection,
// OlcrtcURI). "OlcRTC" remains the brand's display spelling (UI title, app name).
struct OlcrtcApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

struct MainTabView: View {
    @StateObject  private var store       = ConnectionStore()
    @StateObject  private var tunnel      = TunnelManager()
    @StateObject  private var ipCheck     = IPChecker()
    @StateObject  private var speed       = SpeedTest()
    @StateObject  private var serverStore = ServerHostStore()
    @ObservedObject private var settings  = SettingsStore.shared

    /// One-shot guard so the auto-connect setting only fires on cold start,
    /// not every time the user comes back to the Connections tab.
    @State private var didAutoConnect = false

    var body: some View {
        TabView {
            ConnectionsView(store: store, tunnel: tunnel,
                            ipCheck: ipCheck, speed: speed)
                .tabItem { Label(L10n.tabConnections.localized(), systemImage: "network") }

            ServersView(serverStore: serverStore, connections: store)
                .tabItem { Label(L10n.tabServers.localized(), systemImage: "server.rack") }

            LogsView()
                .tabItem { Label(L10n.tabLogs.localized(), systemImage: "doc.text") }

            SettingsView()
                .tabItem { Label(L10n.tabSettings.localized(), systemImage: "gearshape") }
        }
        // Prevent the keyboard from incorrectly resizing tab content. SwiftUI
        // TabView already accounts for the home-indicator / tab-bar safe area,
        // but without this modifier the keyboard safe area can bleed through
        // and push scrollable content under the tab bar on some configurations.
        .ignoresSafeArea(.keyboard)
        // App-wide font scaling. DynamicTypeSize cascades into every system
        // font in the view tree — caption, headline, body, etc. — so this
        // single modifier rescales the whole app.
        .dynamicTypeSize(settings.resolvedTypeSize)
        .onAppear {
            guard !didAutoConnect else { return }
            didAutoConnect = true
            LogStore.shared.log(.connection, "▶ \(LogStore.appVersionString())")
            if settings.autoConnectOnLaunch, let p = store.primary {
                LogStore.shared.log(.connection,
                    "▶ Auto-connect on launch → \(p.displayName)")
                tunnel.connect(record: p)
            }
        }
    }
}
