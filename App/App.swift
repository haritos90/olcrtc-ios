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
    /// #334: the host whose container-log fetch is currently running (set by
    /// LogsView for the duration of the fetch). ServersView observes it to show
    /// a busy indicator on that host's card — the fetch itself lives on the
    /// Logs tab (#339), so this is the only handle ServersView has on it.
    @Published var fetchingHostID: UUID?
}

struct MainTabView: View {
    @StateObject  private var store       = ConnectionStore()
    @StateObject  private var tunnel      = TunnelManager()
    @StateObject  private var ipCheck     = IPChecker()
    @StateObject  private var speed       = SpeedTest()
    @StateObject  private var serverStore = ServerHostStore()
    @StateObject  private var logsRouter  = LogsRouter()   // #339
    @StateObject  private var updateChecker = UpdateChecker()   // #360
    @ObservedObject private var settings  = SettingsStore.shared

    /// #375: re-hydrate Keychain secrets when the app returns to the foreground.
    /// If the device was locked before first unlock at launch, the encryption key
    /// couldn't be read (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) and was
    /// left empty — re-reading on `.active` (after the user has unlocked) fixes it
    /// before they can hit Connect.
    @Environment(\.scenePhase) private var scenePhase

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
    // #354: a bare olcrtc:// deep link reuses the same confirm sheet, wrapped as
    //   a one-entry list with `subSourceLink == nil` (plain add, no dedup).
    // #356: `subSourceLink` is the canonical olcrtc-sub:// link for a real
    //   subscription import — it keys the dedup/refresh bookkeeping in the store.
    @State private var subPrompt: OlcrtcSubscription?
    @State private var subSource = ""             // host/title shown in the confirm message
    @State private var subSourceLink: String?     // canonical olcrtc-sub:// link (nil for plain olcrtc://)
    @State private var subError: String?
    /// #366: parsed full-access (co-admin) link awaiting the user's confirm.
    @State private var fullAccessPrompt: FullAccessShare?
    // eoc #111

    var body: some View {
        // #258 shell pass: every tab uses a large title + a single trailing slot
        // (Connections / VPS: +, Logs: ⋯ overflow, Settings: none). Dark-only is
        // enforced via Info.plist `UIUserInterfaceStyle=Dark` (project.yml).
        TabView(selection: $selectedTab) {
            ConnectionsView(store: store, tunnel: tunnel,
                            ipCheck: ipCheck, speed: speed,
                            onPasteImport: handlePastedImport)   // #361
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
        // #375: on every return to the foreground, re-read Keychain secrets. If
        // the device was locked at launch the encryption key was unreadable and
        // left empty (which would later surface as the misleading "key length 0");
        // re-hydrating after the user unlocks restores it before they Connect.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.rehydrateSecrets() }
        }
        // boc #111: subscription links. olcrtc-sub://host/path → fetch
        // https://host/path (SubscriptionFetcher), parse the sub.md body,
        // then confirm before importing into the regular ConnectionStore.
        .onOpenURL { handleIncomingURL($0) }
        .alert(L10n.subImportTitle.localized(), isPresented: Binding(
            get: { subPrompt != nil },
            set: { if !$0 { subPrompt = nil; subSourceLink = nil } }   // #354/#356: clear provenance on dismiss
        )) {
            Button(L10n.subImportAddAction.localized()) { importSubscription() }
            Button(L10n.cancel.localized(), role: .cancel) { subPrompt = nil; subSourceLink = nil }
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
        // #366: confirm a full-access (co-admin) import behind a destructive
        // warning — it saves the VPS SSH password to this device.
        .alert(L10n.fullAccessImportTitle.localized(), isPresented: Binding(
            get: { fullAccessPrompt != nil },
            set: { if !$0 { fullAccessPrompt = nil } }
        )) {
            Button(L10n.fullAccessImportAddAction.localized(), role: .destructive) { importFullAccess() }
            Button(L10n.cancel.localized(), role: .cancel) { fullAccessPrompt = nil }
        } message: {
            Text(L10n.fullAccessImportBody_fmt.formatted(fullAccessPrompt?.label ?? ""))
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
        // #360: interval-gated, anonymous GitHub-Releases update check. No-op
        // when disabled or checked within 24h; tolerates failure silently. On a
        // newer release it sets `available`, which raises the sheet below.
        .task { await updateChecker.checkIfDue() }
        .sheet(item: $updateChecker.available) { update in
            UpdateAvailableSheet(update: update)
        }
    }

    // boc #111: subscription-link handling

    /// Entry point for URLs opened with the app's registered schemes.
    /// `olcrtc-sub://` fetches and imports a whole list; #354: a bare
    /// `olcrtc://` link routes into the *same* confirm-then-add sheet for the
    /// single connection it encodes (instead of doing nothing).
    private func handleIncomingURL(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "olcrtc-sub": handleSubscriptionURL(url)
        case "olcrtc":
            // #366: a full-access (co-admin) link is `olcrtc://host/v1/…`; a
            // plain connection link is `olcrtc://<carrier>?…` (#354).
            if FullAccessShare.isFullAccessLink(url.absoluteString) {
                handleFullAccessURL(url)
            } else {
                handleConnectionURL(url)
            }
        default:           break
        }
    }

    private func handleSubscriptionURL(_ url: URL) {
        // olcrtc-sub:// → https swap; the canonical sub link keys the dedup.
        guard let fetchURL = try? OlcrtcSubscription.httpsURL(from: url) else {
            subError = OlcrtcSubscription.SubError.invalidSubURL.errorDescription
            return
        }
        fetchAndPromptSubscription(fetchURL: fetchURL, sourceLink: url.absoluteString)
    }

    /// #361: fetch a subscription body from `fetchURL` (HTTPS), parse it, and raise
    /// the confirm prompt. `sourceLink` keys the #356 dedup/refresh bookkeeping —
    /// the original olcrtc-sub:// link for a deep link, or the https URL itself for
    /// a pasted https subscription. Shared by `handleSubscriptionURL` and the paste
    /// route.
    private func fetchAndPromptSubscription(fetchURL: URL, sourceLink: String) {
        Task {
            do {
                LogStore.shared.log(.connection,
                    "⬇ subscription fetch → \(fetchURL.host ?? fetchURL.absoluteString)")
                let body = try await SubscriptionFetcher.fetch(from: fetchURL)
                try presentSubscriptionPrompt(
                    OlcrtcSubscription.parse(body),
                    sourceLink: sourceLink,
                    fallbackSource: fetchURL.host ?? fetchURL.absoluteString)
            } catch {
                LogStore.shared.log(.connection,
                    "✗ subscription import failed: \(error.localizedDescription)")
                subError = error.localizedDescription
            }
        }
    }

    /// #361: validate a parsed subscription and raise the confirm prompt, or throw
    /// `emptySubscription`. Factored out so the deep-link, https-paste, and
    /// raw-body-paste routes all confirm the same way.
    private func presentSubscriptionPrompt(_ sub: OlcrtcSubscription,
                                           sourceLink: String?,
                                           fallbackSource: String) throws {
        guard !sub.entries.isEmpty else {
            throw OlcrtcSubscription.SubError.emptySubscription
        }
        if sub.skippedURIs > 0 {
            LogStore.shared.log(.connection,
                "⚠ subscription: skipped \(sub.skippedURIs) unparseable URI line(s)")
        }
        subSource     = sub.name ?? fallbackSource
        subSourceLink = sourceLink
        subPrompt     = sub
    }

    /// #361: route a blob pasted into the AddConnection import box. A single
    /// olcrtc:// link is left to the editor (it fills the fields); the subscription
    /// routes (https URL / raw sub.md body) come here and join the same
    /// confirm-then-import + #356 dedup flow as a deep link.
    private func handlePastedImport(_ input: OlcrtcSubscription.ImportInput) {
        switch input {
        case .subscriptionURL(let url):
            // HTTPS-only (preserve the ATS / #008–#009 posture). olcrtc-sub:// is
            // swapped to https; a plain https URL is fetched as-is and keys dedup
            // on itself.
            if url.scheme?.lowercased() == "olcrtc-sub" {
                handleSubscriptionURL(url)
            } else if url.scheme?.lowercased() == "https" {
                fetchAndPromptSubscription(fetchURL: url, sourceLink: url.absoluteString)
            } else {
                subError = OlcrtcSubscription.SubError.invalidSubURL.errorDescription
            }
        case .subscriptionBody(let body):
            // Raw sub.md text — parse in place; no source link, so this is a plain
            // (non-deduping) add, like a single olcrtc:// link (#354).
            do {
                try presentSubscriptionPrompt(
                    OlcrtcSubscription.parse(body),
                    sourceLink: nil,
                    fallbackSource: L10n.subImportPastedSource.localized())
            } catch {
                subError = error.localizedDescription
            }
        case .connectionURI, .unrecognized:
            break   // the editor handles a single link; unrecognized → no-op
        }
    }

    /// #354: a single olcrtc:// link → the same confirm-then-add sheet, wrapped
    /// as a one-entry list with no source link (plain add, no subscription
    /// dedup/provenance).
    private func handleConnectionURL(_ url: URL) {
        do {
            // The OS may percent-encode payload chars ([ ] < > &) when forming
            // the URL; try the raw form first, then a decoded fallback.
            let raw = url.absoluteString
            let candidate = (try? OlcrtcURI.parse(raw)) != nil
                ? raw : (raw.removingPercentEncoding ?? raw)
            let parsed = try OlcrtcURI.parse(candidate)
            var sub = OlcrtcSubscription()
            sub.entries = [OlcrtcSubscription.Entry(parsed: parsed, name: nil)]
            subSource     = parsed.mimo.isEmpty ? "\(parsed.carrier) · \(parsed.transport)" : parsed.mimo
            subSourceLink = nil
            subPrompt     = sub
        } catch {
            LogStore.shared.log(.connection,
                "✗ olcrtc:// link parse failed: \(error.localizedDescription)")
            subError = error.localizedDescription
        }
    }

    /// #366: a full-access (co-admin) `olcrtc://host/v1/…` link → parse and raise
    /// the destructive confirm; `importFullAccess` then adds BOTH the connection
    /// and the VPS host (with its SSH password) to this device.
    private func handleFullAccessURL(_ url: URL) {
        do {
            fullAccessPrompt = try FullAccessShare.parse(url.absoluteString)
        } catch {
            LogStore.shared.log(.connection, "✗ full-access link parse failed")
            subError = L10n.fullAccessImportInvalid.localized()
        }
    }

    /// #366: confirmed full-access import — add the connection (like #354) AND
    /// register the VPS host, writing its SSH password to the Keychain. The
    /// password is NEVER logged (only the action + the host coordinates).
    private func importFullAccess() {
        guard let fa = fullAccessPrompt else { return }
        // #383: parse the embedded connection URI FIRST and bail on failure — a
        // malformed URI must NOT silently store the VPS host + SSH password. (#383
        // was: the host add + success log sat OUTSIDE this guard, so a bad URI
        // wrote credentials to the Keychain with no connection and no error.)
        guard let p = try? OlcrtcURI.parse(fa.uri) else {
            LogStore.shared.log(.connection,
                "✗ full-access import failed: embedded connection URI is invalid — nothing stored")
            subError = L10n.fullAccessImportInvalid.localized()
            fullAccessPrompt = nil
            return
        }
        let params = OlcrtcConnection(
            carrier: p.carrier, transport: p.transport, roomID: p.roomID,
            key: p.key, clientID: p.clientID,
            vp8FPS: p.vp8FPS, vp8BatchSize: p.vp8BatchSize,
            seiFPS:  p.seiFPS  ?? 30, seiBatch: p.seiBatch ?? 10,
            seiFrag: p.seiFrag ?? 1200, seiACK:  p.seiACK  ?? 1)
        store.add(ConnectionRecord(name: fa.label,
                                   groupName: ConnectionRecord.defaultGroupName,
                                   details: .olcrtc(params)))
        // #384: route the VPS host through the same dedup + #323 label-collision
        // checks AddServerHostView enforces, instead of a blind serverStore.add:
        // re-opening the same link refreshes the existing card (no duplicate VPS
        // / Keychain entry), and a label clashing with a *different* host is
        // disambiguated so the two don't share a `<prefix>_container.log`.
        let candidate = ServerHost(label: fa.label, host: fa.sshHost,
                                   port: fa.sshPort, username: fa.sshUsername)
        switch ServerHostStore.resolveImport(candidate, into: serverStore.hosts) {
        case .updateExisting(let existing):
            serverStore.update(existing, password: fa.sshPassword)
            LogStore.shared.log(.connection,
                "⬇ full-access import: refreshed VPS \(existing.label) (\(existing.username)@\(existing.host):\(existing.port))")
        case .addNew(let host):
            serverStore.add(host, password: fa.sshPassword)
            LogStore.shared.log(.connection,
                "⬇ imported full-access: connection + VPS \(host.label) (\(host.username)@\(host.host):\(host.port))")
        }
        fullAccessPrompt = nil
    }

    /// Confirmed import. A real subscription (`subSourceLink != nil`) goes
    /// through the diffing store import (#356: add/update/remove, no dup); a
    /// plain olcrtc:// link (#354) is a one-off add of its single entry.
    private func importSubscription() {
        guard let sub = subPrompt else { return }
        if let source = subSourceLink {
            store.importSubscription(sub, source: source)   // #356
        } else {
            // #354: single connection, no subscription provenance.
            let group = sub.name ?? ConnectionRecord.defaultGroupName
            for entry in sub.entries {
                let p = entry.parsed
                // #355: sei params carried through (defaults when a key is absent).
                let params = OlcrtcConnection(
                    carrier: p.carrier, transport: p.transport, roomID: p.roomID,
                    key: p.key, clientID: p.clientID,
                    vp8FPS: p.vp8FPS, vp8BatchSize: p.vp8BatchSize,
                    seiFPS:  p.seiFPS  ?? 30, seiBatch: p.seiBatch ?? 10,
                    seiFrag: p.seiFrag ?? 1200, seiACK:  p.seiACK  ?? 1)
                store.add(ConnectionRecord(name: entry.recordName,
                                           groupName: group,
                                           details: .olcrtc(params)))
            }
            LogStore.shared.log(.connection,
                "⬇ imported \(sub.entries.count) connection(s) from olcrtc:// link")
        }
        subPrompt     = nil
        subSourceLink = nil
    }
    // eoc #111
}
