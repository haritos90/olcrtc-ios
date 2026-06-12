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

    @AppStorage("olcrtc_routing_mode") private var routingRaw = RoutingMode.allTunnel.rawValue

    @State private var showAdd        = false
    @State private var editConn       : ConnectionRecord?
    @State private var qrConn         : ConnectionRecord?
    // #304 was: shareConn + pendingQRConn — the "Share connection" sheet moved to
    // the Manage VPS server card (ShareConnectionView). Copy URI / QR stay here as
    // per-connection quick utilities.
    /// #264: timestamp of the last IP check, shown as a small caption.
    @State private var ipCheckTime    : Date?

    /// #274: per-row health-check state, keyed by connection id. Absent = never
    /// run. One action runs both probes — time-to-ready (#242) + RTT (#234) — and
    /// shows one combined result, replacing the old dual ping/ready chips.
    @State private var healthState    : [UUID: HealthRowState] = [:]

    private enum HealthRowState: Equatable {
        case checking
        case done(ready: PingOutcome, rtt: PingOutcome)
    }

    private var routingMode: RoutingMode { RoutingMode(rawValue: routingRaw) ?? .allTunnel }

    // #273: `.allDirect` forces the app's own traffic (IP check / speed test /
    // in-app SOCKSSession) off the tunnel even while connected — a global kill
    // switch; otherwise route through the tunnel only when it's actually up.
    private var currentMode: RouteMode {
        routingMode == .allDirect ? .direct : (tunnel.state.isConnected ? .tunnel : .direct)
    }

    var body: some View {
        NavigationStack {
            List {
                Section { heroCard.olcCardRow() }

                Section {
                    OlcCard {
                        OlcSegmented(selection: routingBinding,
                                     options: RoutingMode.allCases.map { ($0, $0.title) })
                    }
                    .olcCardRow()
                } header: {
                    Text(L10n.routingHeader.localized())
                }

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

                serversSection
            }
            .navigationTitle("OlcRTC")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddConnectionView(existingGroups: store.allGroupNames) {
                    store.add($0)
                }
            }
            .sheet(item: $editConn) { conn in
                AddConnectionView(existing: conn,
                                  existingGroups: store.allGroupNames) {
                    store.update($0)
                }
            }
            .sheet(item: $qrConn) { conn in
                NavigationStack {
                    QRCodeView(uri: Self.uriOf(conn))
                        .padding(32)
                        .navigationTitle(conn.displayName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.actionDone.localized()) { qrConn = nil }
                            }
                        }
                }
                .presentationDetents([.medium])
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
                Text(L10n.socksProxyAddr_fmt.formatted(String(SettingsStore.shared.socksPort)))
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
                        tunnel.connect(record: p)
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

    private var globalToggleBinding: Binding<Bool> {
        Binding(
            // `.waitingForNetwork` keeps the toggle ON (we're actively holding
            // the session, not disconnected) while staying enabled so the user
            // can flip it off to give up — see `.disabled` on the toggle (#269).
            get: { tunnel.state.isConnected || tunnel.state.isConnecting
                || tunnel.state == .waitingForNetwork },
            set: { on in
                if on, let p = store.primary {
                    tunnel.connect(record: p)
                } else if !on {
                    tunnel.disconnect()
                }
            }
        )
    }

    // MARK: 2. Routing

    private var routingBinding: Binding<RoutingMode> {
        Binding(
            get: { routingMode },
            set: { newMode in
                let prev = routingMode
                routingRaw = newMode.rawValue
                if prev != newMode {
                    LogStore.shared.log(.connection,
                        "↻ routing mode: \(prev.title) → \(newMode.title)")
                }
            }
        )
    }

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
            Text(L10n.ipSourcesAgree_fmt.formatted(ip, ipCheck.results.filter { $0.ip != nil }.count))
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
                            Text(ip).font(.system(.caption2, design: .monospaced))
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
                        showAdd = true
                    }
                    .olcCardRow()
                }
            } else {
                ForEach(store.grouped(), id: \.group) { group in
                    Section(ConnectionRecord.displayGroupName(group.group)) {
                        ForEach(group.items) { conn in
                            serverRow(conn)
                        }
                    }
                }
            }
        }
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
            }

            Spacer()

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
            Button { editConn = conn } label: {
                Label(L10n.edit.localized(), systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    /// #258: the single COMPLETE action set for a row — what was previously split
    /// across a long-press gesture, a pencil button, and a contextMenu.
    private func serverMenuItems(_ conn: ConnectionRecord) -> [OlcMenuItem] {
        var items: [OlcMenuItem] = []
        if store.primary?.id != conn.id {
            items.append(.action(L10n.actionConnect.localized(), systemImage: "play.fill") {
                store.setPrimary(conn.id)
                tunnel.connect(record: conn)
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
            qrConn = conn
        })
        items.append(.divider)
        items.append(.action(L10n.edit.localized(), systemImage: "pencil") { editConn = conn })
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
