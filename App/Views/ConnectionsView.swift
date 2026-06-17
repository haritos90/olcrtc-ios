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

    // #406 was: @State carrierHostIPs / carrierResolving + an inline Section that
    // appeared the moment the tunnel connected. The carrier-endpoint exclusions
    // (#328) now live behind a Diagnostics button that opens CarrierEndpointsView,
    // which owns its own resolve state — so the Connections layout no longer
    // shifts when a session comes up.

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

    /// #403: cache the per-group subscription metadata so `body` doesn't call
    /// `store.subscriptionInfo(for:)` for every group on every render — `body`
    /// re-evaluates whenever ANY observed object publishes, e.g. ~10×/s while a
    /// speed test runs, recomputing this for each group each time. It only actually
    /// changes when the connection list or the stored subscription meta changes, so
    /// derive it then (`recomputeSubInfo()` on appear + the two `.onChange`s) and
    /// read the cache in the footer. Keyed by group name. #403 was: a direct
    /// `store.subscriptionInfo(for: group.items)` call inside the `serversSection`
    /// footer, run on every body pass.
    @State private var subInfoByGroup : [String: (source: String, meta: ConnectionStore.SubscriptionMeta)] = [:]

    /// #413: cache the grouped connection list so the server section doesn't call
    /// `store.grouped()` (Dictionary grouping + sort) on every `body` pass — rebuilt
    /// only when the connection list / stored meta change, alongside the #403
    /// sub-meta cache, in `recompute()`.
    @State private var groups : [(group: String, items: [ConnectionRecord])] = []

    /// #330: the single sheet this view can present. `Identifiable` drives one
    /// `.sheet(item:)`; `edit`/`qr` carry an immutable record snapshot, so the
    /// editor binds a value, not the live store object that churns while a
    /// session is up. `id` is stable per presentation (the connection's id, or a
    /// fixed token for the create sheet) so SwiftUI doesn't re-present mid-edit.
    private enum ConnectionSheet: Identifiable {
        case add
        case edit(ConnectionRecord)
        case qr(ConnectionRecord)
        case carrierEndpoints(OlcrtcConnection)   // #406

        var id: String {
            switch self {
            case .add:              return "add"
            case .edit(let c):      return "edit-\(c.id.uuidString)"
            case .qr(let c):        return "qr-\(c.id.uuidString)"
            case .carrierEndpoints: return "carrier"
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
                            // #406: carrier endpoints moved into Diagnostics as a
                            // button that opens a sheet — no more card that pops in
                            // on connect and shifts the screen.
                            Divider().overlay(Theme.Palette.separator)
                            carrierRow
                        }
                        .padding(.horizontal, Theme.Metrics.cardPadding)
                    }
                    .olcCardRow()
                } header: {
                    Text(L10n.diagnosticsTitle.localized())
                }

                serversSection
            }
            // #411: pull-to-refresh force-refreshes every subscription source now
            // (ignoring each source's #refresh interval). serversSection shows a
            // hint that the gesture refreshes subscriptions.
            .refreshable { await refreshSubscriptions() }
            // #403/#413: keep the cached grouped list + per-group subscription-meta
            // map in sync with their inputs (the connection list + stored meta)
            // rather than recomputing in `body`. `initial:` seeds them on appear.
            .onChange(of: store.connections, initial: true) { _, _ in recompute() }
            .onChange(of: store.subscriptionMeta) { _, _ in recompute() }
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
                case .carrierEndpoints(let params):
                    // #406: the carrier-endpoint exclusions (#328), now a sheet
                    // with copy-host / copy-IP / copy-both actions. It resolves on
                    // appear and owns its own state.
                    CarrierEndpointsView(params: params)
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
                        tunnel.connect(record: p)   // #393: guard now in TunnelManager.connect
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
                    tunnel.connect(record: p)   // #393: guard now in TunnelManager.connect
                } else if !on {
                    tunnel.disconnect()
                }
            }
        )
    }

    // #393 was: connectGuarded(_:) — a view-level wrapper that checked
    // `store.secretsLocked` and surfaced the unlock message before
    // `tunnel.connect`. The guard (and its messaging) moved INTO
    // `TunnelManager.connect` (MainTabView injects `tunnel.secretsLocked =
    // { store.secretsLocked }`), so every caller — including auto-connect-on-launch,
    // which bypassed this wrapper (#393) — is now covered. The wrapper became a
    // redundant indirection; call sites call `tunnel.connect(record:)` directly.

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
            HStack(alignment: .top, spacing: 16) {
                // #291: restore the measurement units next to the numbers — a bare
                // "0.77" is ambiguous. #311: labels/formats through L10n.
                // #405: the unit now rides on the label line ("DL · Mbps") so the
                // value column holds the full decimal — "40.7" used to overflow
                // and wrap its fractional part to a second line. The unit shows
                // unconditionally (it labels the column even before a test runs).
                // #405 was: unit passed via speedUnit(...) after the value.
                OlcMetric(label: L10n.speedLabelPing.localized(),
                          value: speedValue(speed.lastResult?.pingMs, L10n.speedPingValue_fmt.localized()),
                          unit: L10n.speedUnitMs.localized(), unitInLabel: true)
                OlcMetric(label: L10n.speedLabelDL.localized(),
                          value: speedValue(speed.lastResult?.downloadMbps, L10n.speedRateValue_fmt.localized()),
                          unit: L10n.speedUnitMbps.localized(), unitInLabel: true)
                OlcMetric(label: L10n.speedLabelUL.localized(),
                          value: speedValue(speed.lastResult?.uploadMbps, L10n.speedRateValue_fmt.localized()),
                          unit: L10n.speedUnitMbps.localized(), unitInLabel: true)
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

    // #405 was: speedUnit(_:_:) — the unit now lives on the metric's label line
    // (OlcMetric `unitInLabel`), shown unconditionally, so the per-value gate is
    // gone.

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
    // #389 was: `case .olcrtc(let p)? = store.primary?.details` — `store.primary`
    // is the UI selection, which a no-reconnect row tap desyncs from the live node,
    // so the carrier card showed the WRONG carrier's host (wrong DIRECT-rule
    // guidance). Derive from `tunnel.connectedRecord` (the live node, already gated
    // on `.isConnected`) so the card always reflects the node the tunnel holds.
    // (#406 already removed the old `carrierHostIPs` state from this view, so there
    // is nothing else here to keep consistent — `CarrierEndpointsView` resolves the
    // host it is handed.)
    private var activeOlcrtcParams: OlcrtcConnection? {
        guard case .olcrtc(let p)? = tunnel.connectedRecord?.details else { return nil }
        return p
    }

    /// #406: a Diagnostics row that opens the carrier-endpoint exclusions
    /// (#328) on demand. The button is enabled (accent) only while connected to
    /// an olcrtc node — the debug info isn't needed otherwise, and gating it
    /// keeps the card from changing on connect/disconnect. #406 was: an inline
    /// Section (`carrierEndpointsSection`) that appeared the moment a tunnel came
    /// up and shifted the whole screen.
    private var carrierRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.carrierEndpointsTitle.localized())
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(activeOlcrtcParams != nil
                     ? L10n.carrierEndpointsReadyHint.localized()
                     : L10n.carrierEndpointsConnectHint.localized())
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer(minLength: 8)
            OlcButton(L10n.carrierEndpointsCheckAction.localized(), role: .secondary) {
                if let params = activeOlcrtcParams { activeSheet = .carrierEndpoints(params) }
            }
            .disabled(activeOlcrtcParams == nil)
        }
        .padding(.vertical, 12)
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
                // #411: hint that pulling the list down refreshes subscriptions —
                // shown only when at least one subscription source exists.
                if store.hasSubscriptions {
                    Section {
                        Label(L10n.pullToRefreshSubscriptions.localized(), systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                    }
                }
                ForEach(groups, id: \.group) { group in
                    Section {
                        ForEach(group.items) { conn in
                            serverRow(conn)
                        }
                    } header: {
                        groupHeader(group.group, items: group.items)
                    } footer: {
                        // #363: subscription-backed groups surface their source +
                        // quota + refresh below the rows; manual groups show nothing.
                        // #403 was: store.subscriptionInfo(for: group.items) computed
                        // here on every render — now read from the cached map keyed by
                        // group name (refreshed only when connections / meta change).
                        if let info = subInfoByGroup[group.group] {
                            subscriptionMetaFooter(source: info.source, meta: info.meta)
                        }
                    }
                }
            }
        }
    }

    /// #403/#413: rebuild the cached grouped list + the per-group subscription-meta
    /// map from the store. Runs only when the inputs change (connections /
    /// subscriptionMeta), not on every render.
    private func recompute() {
        let grouped = store.grouped()
        groups = grouped
        var map: [String: (source: String, meta: ConnectionStore.SubscriptionMeta)] = [:]
        for group in grouped {
            if let info = store.subscriptionInfo(for: group.items) {
                map[group.group] = info
            }
        }
        subInfoByGroup = map
    }

    /// #411: manual pull-to-refresh — force-refresh every subscription source now.
    /// A no-op when there are no subscriptions (the hint isn't shown then either).
    private func refreshSubscriptions() async {
        guard store.hasSubscriptions else { return }
        _ = await store.refreshAllSources()
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
            // #388 was: `pingGroup(items, connectedNode: tunnel.state.isConnected ?
            // store.primary : nil)` — `store.primary` is the UI selection, which a
            // no-reconnect row tap desyncs from the live node, so the skip missed the
            // genuinely-connected node and pinged it as a 2nd client in its room.
            // `pingGroup` now reads the live node from `tunnel.connectedRecord`
            // itself (re-read each iteration), so the caller passes nothing.
            let results = await tunnel.pingGroup(items) { id, outcome in
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

        // #410: each connection is its own OlcCard on a cleared row (inset 16 via
        // olcCardRow), so its plate width lines up with the hero / diagnostics
        // cards above and the Manage VPS host cards. #410 was: a bare List row
        // whose default inset-grouped cell plate sat ~16 pt wider per side than
        // the cards, which a sharp eye reads as a misaligned, slightly longer row.
        return OlcCard {
          HStack(spacing: 12) {
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
        }
        .olcCardRow()
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
                tunnel.connect(record: conn)   // #393: guard now in TunnelManager.connect
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
            // #407: run the RTT probe first. Each probe establishes its OWN
            // isolated WebRTC session (~5 s of setup), and a successful RTT
            // already proves the transport reached ready — so in the common
            // (healthy) case we skip the separate time-to-ready probe and the
            // health check takes ~one session setup instead of two for a single
            // "32 ms" result. Only when RTT fails do we run checkReady, to keep
            // the "transport ready but data path down" (amber) distinction.
            // #407 was: ready = checkReady(); rtt = ping() — always both, serial.
            let rtt = await tunnel.ping(conn.details)
            if case .success = rtt {
                healthState[conn.id] = .done(ready: rtt, rtt: rtt)
                LogStore.shared.log(.connection, L10n.healthResultRTT_fmt.formatted(
                    conn.displayName, Self.healthValue(rtt)))
            } else {
                let ready = await tunnel.checkReady(conn.details)
                healthState[conn.id] = .done(ready: ready, rtt: rtt)
                LogStore.shared.log(.connection, L10n.healthResult_fmt.formatted(
                    conn.displayName, Self.healthValue(ready), Self.healthValue(rtt)))
            }
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
