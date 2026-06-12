import SwiftUI

// MARK: - App entry
//
// Hosts the root TabView with five tabs:
//   - Connections — server list, global toggle, status, IP/speed test triggers
//   - VPS         — SSH-managed hosts: install / uninstall / reboot olcrtc
//   - Config      — placeholder for routing/config options (#301)
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

// MARK: - Logs routing (#339)
//
// Manage VPS's "Container logs" no longer presents a sheet — it routes to the
// Logs tab (Container category, that host) and auto-starts the fetch there.
// The router is the one piece of shared state: ServersView writes a request,
// MainTabView (which owns the tab selection) switches to the Logs tab, and
// LogsView consumes + clears the request.
@MainActor
final class LogsRouter: ObservableObject {
    struct Request: Equatable {
        let hostID: UUID
        let autofetch: Bool
    }
    @Published var request: Request?
}

struct MainTabView: View {
    @StateObject  private var store       = ConnectionStore()
    @StateObject  private var tunnel      = TunnelManager()
    @StateObject  private var ipCheck     = IPChecker()
    @StateObject  private var speed       = SpeedTest()
    @StateObject  private var serverStore = ServerHostStore()
    @StateObject  private var logsRouter  = LogsRouter()   // #339
    @ObservedObject private var settings  = SettingsStore.shared

    /// One-shot guard so the auto-connect setting only fires on cold start,
    /// not every time the user comes back to the Connections tab.
    @State private var didAutoConnect = false

    /// Selected tab.
    // #294 was: also drove the Logs-tab visibility gate (#289) for the
    // merged-stream rebuild. With per-source Logs tabs (#294) each tab only
    // rebuilds its own small category buffer, so that gate was retired —
    // `selectedTab` now only does normal `TabView` selection.
    @State private var selectedTab = 0

    var body: some View {
        // #258 shell pass: every tab uses a large title + a single trailing slot
        // (Connections / VPS: +, Logs: ⋯ overflow, Settings: none). Dark-only is
        // enforced via Info.plist `UIUserInterfaceStyle=Dark` (project.yml).
        TabView(selection: $selectedTab) {
            ConnectionsView(store: store, tunnel: tunnel,
                            ipCheck: ipCheck, speed: speed)
                .tabItem { Label(L10n.tabConnections.localized(), systemImage: "network") }
                .tag(0)

            // #339: + logsRouter, so "Container logs" can route to the Logs tab.
            ServersView(serverStore: serverStore, connections: store, logsRouter: logsRouter)
                .tabItem { Label(L10n.tabServers.localized(), systemImage: "server.rack") }
                .tag(1)

            // #301: Config placeholder between Manage VPS and Logs (tags shifted +1).
            ConfigView()
                .tabItem { Label(L10n.tabConfig.localized(), systemImage: "slider.horizontal.3") }
                .tag(2)

            // #316 was: LogsView(serverStore: serverStore, isActive: selectedTab == 3)
            // — the isActive flag had been unused since #294; dropped with the
            // single-stack Logs rework.
            // #338: + connections, so the container source card can star the
            // primary connection's host. #339: + router (Manage VPS → Logs).
            LogsView(serverStore: serverStore, connections: store, router: logsRouter)
                .tabItem { Label(L10n.tabLogs.localized(), systemImage: "doc.text") }
                .tag(3)

            // #300: SettingsView needs live tunnel state to gate the
            // "in use by olcrtc tunnel" port-check result on an actual
            // connection, not just the configured port number.
            SettingsView(tunnel: tunnel)
                .tabItem { Label(L10n.tabSettings.localized(), systemImage: "gearshape") }
                .tag(4)
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
        // #340: appearance from the Settings picker (nil = follow the system).
        // The Info.plist UIUserInterfaceStyle=Dark enforcement is gone — it
        // would have overridden this modifier.
        .preferredColorScheme(settings.appearanceMode.colorScheme)
        // #339: a logs request switches to the Logs tab; LogsView consumes the
        // request itself (category + host + autofetch) and clears it to nil —
        // which must not switch tabs again, hence the nil check.
        .onChange(of: logsRouter.request) { _, req in
            if req != nil { selectedTab = 3 }
        }
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
