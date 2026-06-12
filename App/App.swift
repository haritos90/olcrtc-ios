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

    // boc #111: olcrtc-sub:// subscription links. A fetched-and-parsed list
    // waits in `subPrompt` for the user's confirmation ("Add N connections
    // from …?"); `subError` drives the failure alert.
    @State private var subPrompt: OlcrtcSubscription?
    @State private var subSource = ""   // host shown when the list has no #name
    @State private var subError: String?
    // eoc #111

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
            // connection, not just the configured port number (#313: the
            // gate compares against `tunnel.boundPort`, the port the live
            // session actually bound).
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
        // boc #111: subscription links. olcrtc-sub://host/path → fetch
        // https://host/path (SubscriptionFetcher), parse the sub.md body,
        // then confirm before importing into the regular ConnectionStore.
        .onOpenURL { handleIncomingURL($0) }
        .alert(L10n.subImportTitle.localized(), isPresented: Binding(
            get: { subPrompt != nil },
            set: { if !$0 { subPrompt = nil } }
        )) {
            Button(L10n.subImportAddAction.localized()) { importSubscription() }
            Button(L10n.cancel.localized(), role: .cancel) { subPrompt = nil }
        } message: {
            Text(L10n.subImportConfirm_fmt.formatted(
                subPrompt?.entries.count ?? 0,
                subPrompt?.name ?? subSource))
        }
        .alert(L10n.subImportTitle.localized(), isPresented: Binding(
            get: { subError != nil },
            set: { if !$0 { subError = nil } }
        )) {
            Button(L10n.ok.localized()) { subError = nil }
        } message: {
            Text(subError ?? "")
        }
        // eoc #111
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

    // boc #111: subscription-link handling

    /// Entry point for URLs opened with the app's registered schemes.
    /// Only `olcrtc-sub://` does anything today; a plain `olcrtc://` link
    /// still goes through Add connection → Paste URI.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "olcrtc-sub" else { return }
        Task {
            do {
                let source = try OlcrtcSubscription.httpsURL(from: url)
                LogStore.shared.log(.connection,
                    "⬇ subscription fetch → \(source.host ?? source.absoluteString)")
                let body = try await SubscriptionFetcher.fetch(from: source)
                let sub  = OlcrtcSubscription.parse(body)
                guard !sub.entries.isEmpty else {
                    throw OlcrtcSubscription.SubError.emptySubscription
                }
                if sub.skippedURIs > 0 {
                    LogStore.shared.log(.connection,
                        "⚠ subscription: skipped \(sub.skippedURIs) unparseable URI line(s)")
                }
                subSource = source.host ?? source.absoluteString
                subPrompt = sub
            } catch {
                LogStore.shared.log(.connection,
                    "✗ subscription import failed: \(error.localizedDescription)")
                subError = error.localizedDescription
            }
        }
    }

    /// Confirmed import: each subscription entry becomes a regular
    /// ConnectionRecord (same store path as QR / Paste-URI). The list's
    /// `#name` doubles as the group so a subscription's servers stay together.
    private func importSubscription() {
        guard let sub = subPrompt else { return }
        let group = sub.name ?? ConnectionRecord.defaultGroupName
        for entry in sub.entries {
            let p = entry.parsed
            let params = OlcrtcConnection(
                carrier:      p.carrier,
                transport:    p.transport,
                roomID:       p.roomID,
                key:          p.key,
                clientID:     p.clientID,
                vp8FPS:       p.vp8FPS,
                vp8BatchSize: p.vp8BatchSize)
            store.add(ConnectionRecord(name: entry.recordName,
                                       groupName: group,
                                       details: .olcrtc(params)))
        }
        LogStore.shared.log(.connection,
            "⬇ subscription: imported \(sub.entries.count) connection(s) from \(subSource)")
        subPrompt = nil
    }
    // eoc #111
}
