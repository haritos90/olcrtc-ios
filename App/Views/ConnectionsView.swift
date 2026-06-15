import SwiftUI

// MARK: - ConnectionsView
//
// Home tab, top to bottom:
//   1. Hero          — OlcStatusPill (dot + state) + the big connect Toggle, with
//                      the SOCKS5 line / a failure + Retry under a hairline.
//   2. Routing       — OlcSegmented (today only "All through tunnel"; the enum
//                      grows when rules/direct/scene land).
//   3. Diagnostics   — ONE card: IP-check row + speed-test row, identical
//                      secondary buttons. (#258 — was two separate sections.)
//   4. Servers       — grouped rows. Tap a row = set primary (gold star). Each row
//                      carries a single OlcOverflowMenu with the COMPLETE action set.
//
// #258: the per-row actions used to be split between a long-press gesture
// (time-to-ready), a standalone pencil button, and a hidden contextMenu. They are
// now all in the one visible OlcOverflowMenu; the row keeps only tap-to-set-primary
// and a single health-check chip (#274 — one action runs RTT + time-to-ready).

struct ConnectionsView: View {
    @ObservedObject var store   : ConnectionStore
    @ObservedObject var tunnel  : TunnelManager
    @ObservedObject var ipCheck : IPChecker
    @ObservedObject var speed   : SpeedTest
    /// #361: routes a subscription pasted into the AddConnection import box (an
    /// https URL or raw sub.md body) up to MainTabView's confirm-then-import flow.
    /// A single olcrtc:// link is handled inside the editor (fills the fields).
    var onPasteImport: ((OlcrtcSubscription.ImportInput) -> Void)? = nil
    // #337: observe the screenshot-safe toggle so the IP-check rows re-mask live.
    @ObservedObject private var settings = SettingsStore.shared

    // boc #327: routing switch removed for now — it only rerouted the app's own
    // diagnostics (IP check / speed test), never the actual SOCKS tunnel, and the
    // real thing needs upstream/core support (no bypass mode in Mobile.objc.h).
    // Not currently relevant; uncomment this block (and the section/binding below)
    // when routing returns.
    // @AppStorage("olcrtc_routing_mode") private var routingRaw = RoutingMode.allTunnel.rawValue
    // eoc #327

    // #330: ONE enum-driven sheet instead of three sheet modifiers
    // (`showAdd` / `editConn` / `qrConn`) stacked on the same List. Multiple
    // `.sheet` modifiers on one view is unsupported in SwiftUI and, when the
    // host view re-renders under a live tunnel (editing the *current*
    // connection while connected), the editor sheet would hang on present and
    // on dismiss. A single `.sheet(item:)` driven by this enum also hands the
    // editor a stable value snapshot rather than re-deriving it as the host
    // churns. #330 was: @State showAdd/editConn/qrConn + three `.sheet`s.
    @State private var activeSheet: ConnectionSheet?
    // #304 was: shareConn + pendingQRConn — the "Share connection" sheet moved to
    // the Manage VPS server card (ShareConnectionView). Copy URI / QR stay here as
    // per-connection quick utilities.
    /// #264: timestamp of the last IP check, shown as a small caption.
    @State private var ipCheckTime    : Date?

    // boc #328: carrier-endpoint exclusions for the active connection. The
    // base host derives from the connection params (jitsi room URL); its IPs
    // rotate, so they're resolved on demand (resolver pass — Mobile.objc.h
    // exposes no live ICE endpoints, so this is a best-effort hint, not an
    // ICE-accurate list). nil host = the carrier's roomID isn't a host.
    @State private var carrierHostIPs : [String] = []
    @State private var carrierResolving = false
    // eoc #328

    /// #274: per-row health-check state, keyed by connection id. Absent = never
    /// run. One action runs both probes — time-to-ready (#242) + RTT (#234) — and
    /// shows one combined result, replacing the old dual ping/ready chips.
    @State private var healthState    : [UUID: HealthRowState] = [:]

    private enum HealthRowState: Equatable {
        case checking
        case done(ready: PingOutcome, rtt: PingOutcome)
    }

    /// #364: batch "ping group" state. `batchPing` is the latest RTT per node from
    /// the most recent group ping (badged on each row); `pingingGroups` holds the
    /// group names with a sequential ping in flight (disables that group's action
    /// and shows a spinner). Kept separate from `healthState` so a single-row
    /// Health check and a group ping don't clobber each other's display.
    @State private var batchPing      : [UUID: PingOutcome] = [:]
    @State private var pingingGroups  : Set<String> = []

    /// #330: the single sheet this view can present. `Identifiable` drives one
    /// `.sheet(item:)`; `edit`/`qr` carry an immutable record snapshot, so the
    /// editor binds a value, not the live store object that churns while a
    /// session is up. `id` is stable per presentation (the connection's id, or a
    /// fixed token for the create sheet) so SwiftUI doesn't re-present mid-edit.
    private enum ConnectionSheet: Identifiable {
        case add
        case edit(ConnectionRecord)
        case qr(ConnectionRecord)

        var id: String {
            switch self {
            case .add:            return "add"
            case .edit(let c):    return "edit-\(c.id.uuidString)"
            case .qr(let c):      return "qr-\(c.id.uuidString)"
            }
        }
    }

    // boc #327: routing switch removed for now (see the @AppStorage block above)
    // private var routingMode: RoutingMode { RoutingMode(rawValue: routingRaw) ?? .allTunnel }
    // eoc #327

    // #273: `.allDirect` forces the app's own traffic (IP check / speed test /
    // in-app SOCKSSession) off the tunnel even while connected — a global kill
    // switch; otherwise route through the tunnel only when it's actually up.
    // #327 was: routingMode == .allDirect ? .direct : (tunnel.state.isConnected ? .tunnel : .direct)
    private var currentMode: RouteMode {
        tunnel.state.isConnected ? .tunnel : .direct
    }

    var body: some View {
        NavigationStack {
            List {
                Section { heroCard.olcCardRow() }

                // boc #327: routing switch removed for now (see the @AppStorage block)
                // Section {
                //     OlcCard {
                //         OlcSegmented(selection: routingBinding,
                //                      options: RoutingMode.allCases.map { ($0, $0.title) })
                //     }
                //     .olcCardRow()
                // } header: {
                //     Text(L10n.routingHeader.localized())
                // }
                // eoc #327

                Section {
                    OlcCard(padding: 0) {
                        VStack(spacing: 0) {
                            ipRow
                            Divider().overlay(Theme.Palette.separator)
                            speedRow
                        }
                        .padding(.horizontal, Theme.Metrics.cardPadding)
                    }
                    .olcCardRow()
                } header: {
                    Text(L10n.diagnosticsTitle.localized())
                }

                // #328: carrier-endpoint exclusions, only while connected.
                carrierEndpointsSection

                serversSection
            }
            .navigationTitle("OlcRTC")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // #359: icon-only "+" needs an a11y label (reused newConnectionTitle).
                    Button { activeSheet = .add } label: { Image(systemName: "plus") }
                        .accessibilityLabel(L10n.newConnectionTitle.localized())
                }
            }
            // #330: a single sheet modifier (was three stacked `.sheet`s) — see
            // the ConnectionSheet enum. Editing the current connection while
            // connected no longer hangs on open/close.
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .add:
                    AddConnectionView(existingGroups: store.allGroupNames,
                                      onImport: { input in
                                          activeSheet = nil   // #361: hand off to the confirm flow
                                          onPasteImport?(input)
                                      }) {
                        store.add($0)
                    }
                case .edit(let conn):
                    AddConnectionView(existing: conn,
                                      existingGroups: store.allGroupNames) {
                        store.update($0)
                    }
                case .qr(let conn):
                    NavigationStack {
                        QRCodeView(uri: Self.uriOf(conn))
                            .padding(32)
                            .navigationTitle(conn.displayName)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(L10n.actionDone.localized()) { activeSheet = nil }
                                }
                            }
                    }
                    .presentationDetents([.medium])
                }
            }
            // #328: resolve the carrier base host's IPs when the tunnel comes up
            // (and clear them when it goes down) so the exclusions card is
            // populated without a manual tap. IPs rotate — the card offers a
            // re-resolve button too.
            .onChange(of: tunnel.state) { _, _ in
                if let params = activeOlcrtcParams,
                   let host = CarrierEndpoints.baseHost(for: params) {
                    if carrierHostIPs.isEmpty { Task { await resolveCarrierHost(host) } }
                } else {
                    carrierHostIPs = []
                }
            }
        }
    }

    // MARK: 1. Hero

    // #342: fixed-footprint hero (design_handoff_logs_theme §6) — one size in
    // all states. Structure: status row · always-rendered two-line server
    // line · an always-present hairline · a fixed (≈44pt) footer slot that
    // only swaps content. #342 was: the server line collapsed to a one-line
    // hint without a primary, and the SOCKS line / failure row were appended
    // conditionally under their own dividers — the card resized on every
    // state change.
    private var heroCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: 12) {
                OlcStatusPill(tone: heroTone, title: heroTitle) {
                    Toggle("", isOn: globalToggleBinding)
                        .labelsHidden()
                        .disabled(store.primary == nil || tunnel.state.isConnecting)
                        // #359: the app's most important control read as a bare
                        // "Switch" — give it a name, a state value, and a hint
                        // when it's disabled because no connection is selected.
                        .accessibilityLabel(L10n.a11yConnectToggle.localized())
                        .accessibilityValue(connectToggleA11yValue)
                        .accessibilityHint(store.primary == nil
                                           ? L10n.a11yConnectHintSelectFirst.localized() : "")
                }

                // Server line — always two lines; the mono subtitle reserves
                // its line (single space) even with no primary connection.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Text(store.primary?.displayName ?? L10n.emptyNoConnections.localized())
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(store.primary != nil
                                             ? Theme.Palette.textPrimary
                                             : Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Text(store.primary?.subtitle ?? " ")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }

                Divider().overlay(Theme.Palette.separator)

                heroFooter
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .animation(.easeInOut(duration: 0.25), value: tunnel.state)
        }
    }

    /// #342: the footer slot's per-state content — exactly one of hint /
    /// connect progress / SOCKS5 line / failure+Retry, swapped inside the
    /// fixed frame above.
    @ViewBuilder
    private var heroFooter: some View {
        switch tunnel.state {
        case .disconnected:
            Text(store.primary.map { L10n.heroDisconnectedHint_fmt.formatted($0.displayName) }
                 ?? L10n.emptyNoConnectionsHint.localized())
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
        case .connecting:
            // The tunnel exposes a single connecting state (no ICE/signaling
            // sub-phases), so per the handoff this is a slow indeterminate
            // fill — no fake step counts.
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.stateConnecting.localized())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
                HeroIndeterminateFill()
            }
        case .waitingForNetwork:
            Text(L10n.stateWaitingForNetwork.localized())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Palette.textSecondary)
        case .connected:
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.textTertiary)
                // #351 was: SettingsStore.shared.socksPort (the *configured* port) —
                // after a live port edit while connected the hero showed the new,
                // not-yet-bound port. Prefer the port the live session actually bound.
                Text(L10n.socksProxyAddr_fmt.formatted(String(tunnel.boundPort ?? SettingsStore.shared.socksPort)))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        case .failed(let msg):
            HStack(alignment: .center, spacing: 10) {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.red)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let p = store.primary {
                    // #342 was: full-height 44pt Retry — compact 32pt so it
                    // fits the fixed footer slot.
                    OlcButton(L10n.actionRetry.localized(), systemImage: "arrow.clockwise",
                              role: .danger, compact: true) {
                        connectGuarded(p)   // #375
                    }
                }
            }
        }
    }

    private var heroTone: OlcStatusTone {
        if tunnel.state.isConnected { return .ok }
        if tunnel.state.isConnecting { return .progress }
        if tunnel.state == .waitingForNetwork { return .progress }
        if case .failed = tunnel.state { return .error }
        return .unknown
    }

    private var heroTitle: String {
        if tunnel.state.isConnected { return L10n.stateConnected.localized() }
        if tunnel.state.isConnecting { return L10n.stateConnecting.localized() }
        if tunnel.state == .waitingForNetwork { return L10n.stateWaitingForNetwork.localized() }
        if case .failed = tunnel.state { return L10n.stateConnectFailed.localized() }
        return L10n.stateDisconnected.localized()
    }

    /// #359: VoiceOver value for the hero connect toggle — reflects the live
    /// session state (connecting/waiting collapse to "Connecting").
    private var connectToggleA11yValue: String {
        if tunnel.state.isConnected { return L10n.a11yStateConnected.localized() }
        if tunnel.state.isConnecting || tunnel.state == .waitingForNetwork {
            return L10n.a11yStateConnecting.localized()
        }
        return L10n.a11yStateDisconnected.localized()
    }

    private var globalToggleBinding: Binding<Bool> {
        Binding(
            // `.waitingForNetwork` keeps the toggle ON (we're actively holding
            // the session, not disconnected) while staying enabled so the user
            // can flip it off to give up — see `.disabled` on the toggle (#269).
            get: { tunnel.state.isConnected || tunnel.state.isConnecting
                || tunnel.state == .waitingForNetwork },
            set: { on in
                if on, let p = store.primary {
                    connectGuarded(p)
                } else if !on {
                    tunnel.disconnect()
                }
            }
        )
    }

    /// #375: connect, but if Keychain secrets couldn't be read at a locked-device
    /// launch (`store.secretsLocked`) the in-memory key is empty — connecting
    /// would fail validation with the misleading "Key must be 64 hex characters
    /// (got: 0)". Surface the actionable unlock message instead. Foreground
    /// re-hydration (App.swift `.scenePhase == .active`) normally clears the flag
    /// before the user gets here; this guards the locked-then-immediately-tapped
    /// edge. All three connect entry points in this view route through here.
    private func connectGuarded(_ record: ConnectionRecord) {
        if store.secretsLocked {
            tunnel.state = .failed(L10n.errorSecretsLocked.localized())
            return
        }
        tunnel.connect(record: record)
    }

    // MARK: 2. Routing

    // boc #327: routing switch removed for now (see the @AppStorage block)
    // private var routingBinding: Binding<RoutingMode> {
    //     Binding(
    //         get: { routingMode },
    //         set: { newMode in
    //             let prev = routingMode
    //             routingRaw = newMode.rawValue
    //             if prev != newMode {
    //                 LogStore.shared.log(.connection,
    //                     "↻ routing mode: \(prev.title) → \(newMode.title)")
    //             }
    //         }
    //     )
    // }
    // eoc #327

    // MARK: 3. Diagnostics (merged IP-check + speed-test)

    private var ipRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.ipCheckTitle.localized())
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ipStatusContent
                // #264: last-check time (restored — the redesign had dropped it).
                if let t = ipCheckTime, !ipCheck.isChecking {
                    Label(t.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            OlcButton(L10n.ipCheckRun.localized(), role: .secondary, isBusy: ipCheck.isChecking) {
                Task { await ipCheck.checkAll(via: currentMode); ipCheckTime = Date() }
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var ipStatusContent: some View {
        if ipCheck.isChecking {
            Text(L10n.ipChecking.localized())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Palette.textSecondary)
        } else if !ipCheckHasResults {
            Text(L10n.ipNotChecked.localized())
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else if ipCheckCollapsed, let ip = ipCheckSummaryIP {
            // #337: mask the summary IP for display only (the value behind it
            // and any copy stay real).
            Text(L10n.ipSourcesAgree_fmt.formatted(IPMask.display(ip, masked: settings.maskIPs),
                                                   ipCheck.results.filter { $0.ip != nil }.count))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Palette.green)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                // DNS-leak warning: sources returned different IPs.
                if ipCheckAllDone, Set(ipCheck.results.compactMap { $0.ip }).count > 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.red)
                        Text(L10n.ipDnsLeak.localized())
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.red)
                    }
                }
                ForEach(ipCheck.results) { r in
                    HStack {
                        Text(r.label)
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Spacer()
                        if let ip = r.ip {
                            // #337: mask per-source IPs for display only.
                            Text(IPMask.display(ip, masked: settings.maskIPs))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textPrimary)
                        } else if let err = r.error {
                            Text(err).font(.caption2).foregroundStyle(Theme.Palette.red)
                                .lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("—").foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var speedRow: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                // #291: restore the measurement units next to the numbers — a bare
                // "0.77" is ambiguous. #311: labels/formats through L10n.
                // #342 was: unit baked into the value format ("%.0f ms") which
                // inflated the mono number — now OlcMetric's `unit:` renders it
                // as smaller secondary text, only next to a real number.
                OlcMetric(label: L10n.speedLabelPing.localized(),
                          value: speedValue(speed.lastResult?.pingMs, L10n.speedPingValue_fmt.localized()),
                          unit: speedUnit(speed.lastResult?.pingMs, L10n.speedUnitMs.localized()))
                OlcMetric(label: L10n.speedLabelDL.localized(),
                          value: speedValue(speed.lastResult?.downloadMbps, L10n.speedRateValue_fmt.localized()),
                          unit: speedUnit(speed.lastResult?.downloadMbps, L10n.speedUnitMbps.localized()))
                OlcMetric(label: L10n.speedLabelUL.localized(),
                          value: speedValue(speed.lastResult?.uploadMbps, L10n.speedRateValue_fmt.localized()),
                          unit: speedUnit(speed.lastResult?.uploadMbps, L10n.speedUnitMbps.localized()))
            }
            Spacer(minLength: 8)
            OlcButton(L10n.speedTestRun.localized(), role: .secondary, isBusy: speed.isTesting) {
                runSpeedTest()
            }
        }
        .padding(.vertical, 12)
    }

    private func speedValue(_ v: Double?, _ format: String) -> String {
        if speed.isTesting { return "…" }
        guard let v else { return "—" }
        return String(format: format, v)
    }

    /// #342: the unit only accompanies a real number — never "…" or "—".
    private func speedUnit(_ v: Double?, _ unit: String) -> String? {
        !speed.isTesting && v != nil ? unit : nil
    }

    // IP-check display helpers (unchanged logic).
    private var ipCheckCollapsed: Bool {
        let ips = ipCheck.results.compactMap { $0.ip }
        guard ips.count >= 2 else { return false }
        return Set(ips).count == 1
    }
    private var ipCheckSummaryIP: String? { ipCheck.results.compactMap { $0.ip }.first }
    private var ipCheckHasResults: Bool { ipCheck.results.contains { $0.ip != nil || $0.error != nil } }
    private var ipCheckAllDone: Bool {
        !ipCheck.results.isEmpty && ipCheck.results.allSatisfy { $0.ip != nil || $0.error != nil }
    }

    // MARK: 3b. Carrier endpoints (#328 — proxy-loop exclusions)

    /// The active olcrtc connection's params, only while the tunnel is up.
    private var activeOlcrtcParams: OlcrtcConnection? {
        guard tunnel.state.isConnected, case .olcrtc(let p)? = store.primary?.details else { return nil }
        return p
    }

    /// #328: when connected, show the carrier base host + its resolved IPs
    /// (and the proxy-loop exclusion hint) so the user can add DIRECT rules in
    /// a Shadowrocket-style app. Hidden when disconnected. STUN/TURN hosts are
    /// not exposed by the core (Mobile.objc.h), so we don't fabricate them.
    @ViewBuilder
    private var carrierEndpointsSection: some View {
        if let params = activeOlcrtcParams {
            Section {
                OlcCard {
                    VStack(alignment: .leading, spacing: 12) {
                        if let host = CarrierEndpoints.baseHost(for: params) {
                            endpointRow(label: L10n.carrierEndpointHost.localized(), value: host)
                            Divider().overlay(Theme.Palette.separator)
                            resolvedIPsRow(host: host)
                        } else {
                            Text(L10n.carrierEndpointNoHost.localized())
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Text(L10n.carrierEndpointsHint.localized())
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .olcCardRow()
            } header: {
                Text(L10n.carrierEndpointsTitle.localized())
            }
        }
    }

    /// One copyable endpoint: label + monospaced value + a copy button.
    private func endpointRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                copyEndpoint(value)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.copyURIAction.localized())
        }
    }

    /// The resolved-IPs row: a re-resolve action + each IP copyable. IPs rotate,
    /// so the user copies both the host (above) and the current IPs.
    @ViewBuilder
    private func resolvedIPsRow(host: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.carrierEndpointResolvedIPs.localized())
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Button(L10n.carrierEndpointRefresh.localized()) {
                    Task { await resolveCarrierHost(host) }
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .disabled(carrierResolving)
            }
            if carrierResolving {
                Text(L10n.carrierEndpointResolving.localized())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else if carrierHostIPs.isEmpty {
                Text(L10n.carrierEndpointUnresolved.localized())
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                ForEach(carrierHostIPs, id: \.self) { ip in
                    HStack(spacing: 8) {
                        Text(ip)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button { copyEndpoint(ip) } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.copyURIAction.localized())
                    }
                }
            }
        }
    }

    /// Copies an endpoint to the clipboard and logs it (display-only masking
    /// never touches copy — #337 — so the real value goes to the pasteboard).
    private func copyEndpoint(_ value: String) {
        UIPasteboard.general.string = value
        LogStore.shared.log(.connection, L10n.carrierEndpointCopied_fmt.formatted(value))
    }

    /// Resolves the carrier base host's current IPs (DNS pass). Re-runnable —
    /// IPs rotate per carrier load-balancing.
    private func resolveCarrierHost(_ host: String) async {
        guard !carrierResolving else { return }
        carrierResolving = true
        let ips = await CarrierEndpoints.resolve(host: host)
        carrierHostIPs = ips
        carrierResolving = false
    }

    /// Reassembles the original `olcrtc://` URI for sharing / copy / QR.
    private static func uriOf(_ conn: ConnectionRecord) -> String {
        switch conn.details {
        case .olcrtc(let p): return OlcrtcURI.encode(p)
        }
    }

    // MARK: 4. Server list (grouped)

    private var serversSection: some View {
        Group {
            if store.connections.isEmpty {
                Section {
                    OlcEmptyState(systemImage: "network",
                                  title: L10n.emptyNoConnections.localized(),
                                  hint: L10n.emptyNoConnectionsHint.localized(),
                                  ctaTitle: L10n.newConnectionTitle.localized()) {
                        activeSheet = .add   // #330
                    }
                    .olcCardRow()
                }
            } else {
                ForEach(store.grouped(), id: \.group) { group in
                    Section {
                        ForEach(group.items) { conn in
                            serverRow(conn)
                        }
                    } header: {
                        groupHeader(group.group, items: group.items)
                    } footer: {
                        // #363: subscription-backed groups surface their source +
                        // quota + refresh below the rows; manual groups show nothing.
                        if let info = store.subscriptionInfo(for: group.items) {
                            subscriptionMetaFooter(source: info.source, meta: info.meta)
                        }
                    }
                }
            }
        }
    }

    /// #364: group section header — the group name plus a "Ping all" action that
    /// sequentially health-checks every node in the group and badges each row with
    /// its latency. The button is disabled (and shows a spinner) while this group's
    /// ping is in flight.
    @ViewBuilder
    private func groupHeader(_ group: String, items: [ConnectionRecord]) -> some View {
        HStack {
            Text(ConnectionRecord.displayGroupName(group))
            Spacer()
            if pingingGroups.contains(group) {
                ProgressView().controlSize(.mini)
            } else {
                Button(L10n.pingGroupAction.localized(), systemImage: "dot.radiowaves.left.and.right") {
                    runGroupPing(group: group, items: items)
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .textCase(nil)
            }
        }
    }

    /// #364: sequentially ping every node in a group via `TunnelManager.pingGroup`
    /// (each probe leases its own ephemeral port + unique clientID, never the SOCKS
    /// port, and the live tunnel's node is skipped). Results badge each row as they
    /// land; a summary line is logged when the group finishes.
    private func runGroupPing(group: String, items: [ConnectionRecord]) {
        guard !pingingGroups.contains(group) else { return }
        pingingGroups.insert(group)
        // Clear stale badges for this group so partial old results don't linger.
        for c in items { batchPing[c.id] = nil }
        Task {
            let connected = tunnel.state.isConnected ? store.primary : nil
            let results = await tunnel.pingGroup(items, connectedNode: connected) { id, outcome in
                batchPing[id] = outcome
            }
            pingingGroups.remove(group)
            let ok = results.values.filter { if case .success = $0 { return true } else { return false } }.count
            LogStore.shared.log(.connection, L10n.pingGroupResult_fmt.formatted(
                ConnectionRecord.displayGroupName(group), ok, results.count - ok))
        }
    }

    /// #363: per-group subscription metadata, rendered in the section footer for
    /// groups whose nodes came from an olcrtc-sub:// link. All values are
    /// server-provided free text — rendered as plain captions (no styling derived
    /// from server input), through Theme tokens.
    @ViewBuilder
    private func subscriptionMetaFooter(source: String,
                                        meta: ConnectionStore.SubscriptionMeta) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            metaLine(L10n.subMetaSource.localized(), Self.displaySubSource(source))
            if let count = meta.serverCount {
                metaLine(L10n.subMetaServers.localized(), String(count))
            }
            metaLine(L10n.subMetaRefresh.localized(), Self.refreshDisplay(meta.refreshInterval))
            if let used = meta.used, !used.isEmpty {
                metaLine(L10n.subMetaUsed.localized(), used)
            }
            if let available = meta.available, !available.isEmpty {
                metaLine(L10n.subMetaAvailable.localized(), available)
            }
        }
        .padding(.top, 4)
    }

    /// One "label  value" caption row for the subscription footer.
    private func metaLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.caption2)
    }

    /// #363: a readable host for the subscription source link (drops the
    /// scheme/path so the footer shows e.g. "pool.example.org", not the whole
    /// olcrtc-sub:// URL). Falls back to the raw string if it doesn't parse.
    private static func displaySubSource(_ source: String) -> String {
        URL(string: source)?.host ?? source
    }

    /// #363: compact rendering of the stored `#refresh` interval (seconds).
    /// nil → "Never"; otherwise the largest whole unit (d/h/m/s).
    private static func refreshDisplay(_ interval: TimeInterval?) -> String {
        guard let i = interval, i > 0 else { return L10n.subMetaRefreshNever.localized() }
        let s = Int(i)
        let text: String
        switch s {
        case let n where n % 86400 == 0: text = "\(n / 86400)d"
        case let n where n % 3600  == 0: text = "\(n / 3600)h"
        case let n where n % 60    == 0: text = "\(n / 60)m"
        default:                         text = "\(s)s"
        }
        return L10n.subMetaRefreshInterval_fmt.formatted(text)
    }

    private func serverRow(_ conn: ConnectionRecord) -> some View {
        let isPrimary = store.primary?.id == conn.id

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .strokeBorder(isPrimary ? Theme.Palette.star : Theme.Palette.textTertiary,
                                  lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                if isPrimary {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.star)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(conn.displayName)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if isPrimary {
                        Text(L10n.primaryRoleMain.localized())
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.Palette.starWeak)
                            .clipShape(Capsule())
                            .foregroundStyle(Theme.Palette.star)
                    }
                }
                Text(conn.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                // #363: per-node subscription metadata (##ip / ##comment) — both
                // server-provided free text, masked-IP-aware, defensively rendered.
                if conn.subIP != nil || conn.subComment != nil {
                    nodeMetaLine(conn)
                }
            }

            Spacer()

            // #364: latency badge from the most recent group ping, if any.
            if let outcome = batchPing[conn.id] {
                batchPingBadge(outcome)
            }
            healthButton(conn)
            // #258 was: a standalone pencil quick-edit button — removed (Edit is in
            // the overflow menu and the swipe action).
            OlcOverflowMenu(items: serverMenuItems(conn))
        }
        .contentShape(Rectangle())
        .onTapGesture { store.setPrimary(conn.id) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                if let i = store.connections.firstIndex(where: { $0.id == conn.id }) {
                    store.remove(at: IndexSet([i]))
                }
            } label: {
                Label(L10n.actionRemoveFromList.localized(), systemImage: "trash")
            }
            Button { activeSheet = .edit(conn) } label: {   // #330
                Label(L10n.edit.localized(), systemImage: "pencil")
            }
            // #350 was: .tint(.orange) — route through the Theme status token.
            .tint(Theme.Palette.orange)
        }
    }

    /// #364: compact latency pill for a row, populated by a group ping —
    /// the measured RTT (coloured by threshold) or a red marker on failure.
    @ViewBuilder
    private func batchPingBadge(_ outcome: PingOutcome) -> some View {
        switch outcome {
        case .success(let ms):
            Text("\(ms) ms")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Self.latencyColor(ms))
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.red)
        }
    }

    /// #363: the per-node subscription metadata line under a row's subtitle —
    /// `##ip` (masked per #337) and/or `##comment`. Both are server-supplied free
    /// text, so it's a plain caption with no styling derived from the value.
    @ViewBuilder
    private func nodeMetaLine(_ conn: ConnectionRecord) -> some View {
        HStack(spacing: 6) {
            if let ip = conn.subIP, !ip.isEmpty {
                Text(IPMask.display(ip, masked: settings.maskIPs))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            if let comment = conn.subComment, !comment.isEmpty {
                Text(comment)
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// #258: the single COMPLETE action set for a row — what was previously split
    /// across a long-press gesture, a pencil button, and a contextMenu.
    private func serverMenuItems(_ conn: ConnectionRecord) -> [OlcMenuItem] {
        var items: [OlcMenuItem] = []
        if store.primary?.id != conn.id {
            items.append(.action(L10n.actionConnect.localized(), systemImage: "play.fill") {
                store.setPrimary(conn.id)
                connectGuarded(conn)   // #375
            })
        }
        // #274: one "Health check" item runs both probes (RTT + time-to-ready).
        items.append(.action(L10n.healthCheckAction.localized(), systemImage: "waveform.path.ecg") {
            runHealthCheck(conn)
        })
        // #304: "Share connection" moved to the Manage VPS server card. Copy URI /
        // QR remain here as lightweight per-connection utilities.
        items.append(.divider)
        items.append(.action(L10n.copyURIAction.localized(), systemImage: "doc.on.doc") {
            UIPasteboard.general.string = Self.uriOf(conn)
            LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
        })
        items.append(.action(L10n.actionQR.localized(), systemImage: "qrcode") {
            activeSheet = .qr(conn)   // #330
        })
        items.append(.divider)
        items.append(.action(L10n.edit.localized(), systemImage: "pencil") { activeSheet = .edit(conn) })   // #330
        items.append(.action(L10n.actionRemoveFromList.localized(), systemImage: "trash", role: .destructive) {
            if let i = store.connections.firstIndex(where: { $0.id == conn.id }) {
                store.remove(at: IndexSet([i]))
            }
        })
        return items
    }

    // MARK: Per-connection health check (#274 — merges #234 RTT + #242 time-to-ready)

    /// Trailing health chip: a heartbeat glyph that becomes a spinner while
    /// probing, then the measured RTT (or the ready time if RTT failed, or a red
    /// marker if both failed). One tap runs both probes; the full combined result
    /// lands in the log + the accessibility label.
    @ViewBuilder
    private func healthButton(_ conn: ConnectionRecord) -> some View {
        Button {
            runHealthCheck(conn)
        } label: {
            healthChipLabel(conn)
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 28, minHeight: 28)
                .padding(.horizontal, 10)
                .background(Theme.Palette.fill, in: Capsule())
                // #370: grow the TOUCH region to Apple's 44pt minimum without
                // enlarging the drawn chip (the capsule keeps its 28pt height).
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(healthState[conn.id] == .checking)
        .accessibilityLabel(L10n.healthCheckAction.localized())
    }

    @ViewBuilder
    private func healthChipLabel(_ conn: ConnectionRecord) -> some View {
        switch healthState[conn.id] {
        case .checking:
            ProgressView().controlSize(.mini)
        case .done(let ready, let rtt):
            if case .success(let ms) = rtt {
                // Healthy: show RTT (familiar latency pill), coloured by threshold.
                Text("\(ms) ms").foregroundStyle(Self.latencyColor(ms))
            } else if case .success(let ms) = ready {
                // Transport reached ready but the RTT probe failed — show ready, amber.
                HStack(spacing: 3) {
                    Image(systemName: "stopwatch")
                    Text("\(ms) ms").monospacedDigit()
                }
                .foregroundStyle(Theme.Palette.orange)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.red)
            }
        case nil:
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Runs both isolated probes — time-to-ready (#242) then RTT (#234) — and logs
    /// one combined line. The underlying `TunnelManager`/engine probes are
    /// unchanged; only the row UI collapses (#274).
    private func runHealthCheck(_ conn: ConnectionRecord) {
        guard healthState[conn.id] != .checking else { return }
        healthState[conn.id] = .checking
        Task {
            let ready = await tunnel.checkReady(conn.details)
            let rtt   = await tunnel.ping(conn.details)
            healthState[conn.id] = .done(ready: ready, rtt: rtt)
            LogStore.shared.log(.connection, L10n.healthResult_fmt.formatted(
                conn.displayName, Self.healthValue(ready), Self.healthValue(rtt)))
        }
    }

    /// Formats one probe outcome for the combined health log line.
    private static func healthValue(_ outcome: PingOutcome) -> String {
        switch outcome {
        case .success(let ms):  return "\(ms) ms"
        case .failure(let msg): return "n/a (\(msg))"
        }
    }

    /// #285: passes the active carrier/transport into the speed test (when
    /// tunnelled) so the header logs the connection type and the datachannel
    /// hint can fire for slow video transports.
    private func runSpeedTest() {
        var carrier: String?
        var transport: String?
        if currentMode == .tunnel, case .olcrtc(let p)? = store.primary?.details {
            carrier = p.carrier
            transport = p.transport
        }
        Task { await speed.run(via: currentMode, carrier: carrier, transport: transport) }
    }

    /// Green / orange / red thresholds for a SOCKS round-trip in milliseconds.
    private static func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<150:  return Theme.Palette.green
        case ..<400:  return Theme.Palette.orange
        default:      return Theme.Palette.red
        }
    }

}

// #262: `olcCardRow()` now lives in DesignSystem.swift (shared with ServersView).

/// #342: slow indeterminate fill for the hero's single `.connecting` state —
/// asymptotic toward 90% over ~half a minute (the start timeout's order of
/// magnitude), restarting per connect attempt. @State keeps the start across
/// re-renders; the view leaves the hierarchy when the state changes.
private struct HeroIndeterminateFill: View {
    @State private var start = Date()
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 10)) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            OlcProgressBar(fraction: 0.9 * (1 - exp(-t / 8)))
        }
    }
}

// #340: both appearance variants.
#if DEBUG
#Preview("Connections — Dark") {
    ConnectionsView(store: ConnectionStore(), tunnel: TunnelManager(),
                    ipCheck: IPChecker(), speed: SpeedTest())
        .preferredColorScheme(.dark)
}
#Preview("Connections — Light") {
    ConnectionsView(store: ConnectionStore(), tunnel: TunnelManager(),
                    ipCheck: IPChecker(), speed: SpeedTest())
        .preferredColorScheme(.light)
}
#endif
