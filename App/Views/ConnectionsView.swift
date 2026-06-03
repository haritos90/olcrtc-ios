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
// (runCheckReady), a standalone pencil button, and a hidden contextMenu. They are
// now all in the one visible OlcOverflowMenu; the row keeps only tap-to-set-primary
// and the ping chip.

struct ConnectionsView: View {
    @ObservedObject var store   : ConnectionStore
    @ObservedObject var tunnel  : TunnelManager
    @ObservedObject var ipCheck : IPChecker
    @ObservedObject var speed   : SpeedTest

    @AppStorage("olcrtc_routing_mode") private var routingRaw = RoutingMode.allTunnel.rawValue

    @State private var showAdd        = false
    @State private var editConn       : ConnectionRecord?
    @State private var qrConn         : ConnectionRecord?
    @State private var shareConn      : ConnectionRecord?
    @State private var pendingQRConn  : ConnectionRecord?
    /// #264: timestamp of the last IP check, shown as a small caption.
    @State private var ipCheckTime    : Date?

    /// Per-row ping state, keyed by connection id. Absent = never pinged.
    @State private var pingState      : [UUID: PingRowState] = [:]

    private enum PingRowState: Equatable {
        case pinging
        case done(PingOutcome)
    }

    /// Per-row time-to-ready check state (#242). Overlays the ping chip with a
    /// stopwatch result; a re-ping (tap) clears it.
    @State private var checkState     : [UUID: CheckRowState] = [:]

    private enum CheckRowState: Equatable {
        case checking
        case done(PingOutcome)
    }

    private var routingMode: RoutingMode { RoutingMode(rawValue: routingRaw) ?? .allTunnel }

    private var currentMode: RouteMode { tunnel.state.isConnected ? .tunnel : .direct }

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
            .sheet(item: $shareConn) { conn in
                shareConnectionSheet(conn)
            }
            .onChange(of: shareConn) { _, v in
                if v == nil, let p = pendingQRConn {
                    qrConn = p
                    pendingQRConn = nil
                }
            }
        }
    }

    // MARK: 1. Hero

    private var heroCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: 12) {
                OlcStatusPill(tone: heroTone, title: heroTitle) {
                    Toggle("", isOn: globalToggleBinding)
                        .labelsHidden()
                        .disabled(store.primary == nil || tunnel.state.isConnecting)
                }

                if let p = store.primary {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "server.rack")
                                .font(.caption2)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Text(p.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        Text(p.subtitle)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                } else {
                    Text(L10n.emptyNoConnectionsHint.localized())
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                if tunnel.state.isConnected {
                    Divider().overlay(Theme.Palette.separator)
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(L10n.socksProxyAddr_fmt.formatted(String(SettingsStore.shared.socksPort)))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }

                if case .failed(let msg) = tunnel.state {
                    Divider().overlay(Theme.Palette.separator)
                    HStack(alignment: .center, spacing: 10) {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.red)
                        Spacer(minLength: 4)
                        if let p = store.primary {
                            OlcButton(L10n.actionRetry.localized(), systemImage: "arrow.clockwise", role: .danger) {
                                tunnel.connect(record: p)
                            }
                        }
                    }
                }
            }
        }
    }

    private var heroTone: OlcStatusTone {
        if tunnel.state.isConnected { return .ok }
        if tunnel.state.isConnecting { return .progress }
        if case .failed = tunnel.state { return .error }
        return .unknown
    }

    private var heroTitle: String {
        if tunnel.state.isConnected { return L10n.stateConnected.localized() }
        if tunnel.state.isConnecting { return L10n.stateConnecting.localized() }
        if case .failed = tunnel.state { return L10n.stateConnectFailed.localized() }
        return L10n.stateDisconnected.localized()
    }

    private var globalToggleBinding: Binding<Bool> {
        Binding(
            get: { tunnel.state.isConnected || tunnel.state.isConnecting },
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
                OlcMetric(label: "Ping", value: speedValue(speed.lastResult?.pingMs, "%.0f ms"))
                OlcMetric(label: "DL",   value: speedValue(speed.lastResult?.downloadMbps, "%.1f"))
                OlcMetric(label: "UL",   value: speedValue(speed.lastResult?.uploadMbps, "%.1f"))
            }
            Spacer(minLength: 8)
            OlcButton(L10n.speedTestRun.localized(), role: .secondary, isBusy: speed.isTesting) {
                Task { await speed.run(via: currentMode) }
            }
        }
        .padding(.vertical, 12)
    }

    private func speedValue(_ v: Double?, _ format: String) -> String {
        if speed.isTesting { return "…" }
        guard let v else { return "—" }
        return String(format: format, v)
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
                    Section(group.group) {
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

            pingButton(conn)
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
        items.append(.action(L10n.pingButtonA11y.localized(), systemImage: "bolt.horizontal.circle") {
            runPing(conn)
        })
        // #258: time-to-ready check is now a normal menu item (was long-press only).
        items.append(.action(L10n.checkReadyA11y.localized(), systemImage: "stopwatch") {
            runCheckReady(conn)
        })
        items.append(.divider)
        items.append(.action(L10n.shareConnectionTitle.localized(), systemImage: "square.and.arrow.up") {
            shareConn = conn
        })
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

    // MARK: Per-connection ping (#234) + time-to-ready (#242)

    /// Trailing ping chip: a bolt that becomes a spinner while probing, then a
    /// coloured "<n> ms" pill (or a stopwatch result from #242). Tapping re-pings.
    @ViewBuilder
    private func pingButton(_ conn: ConnectionRecord) -> some View {
        Button {
            runPing(conn)
        } label: {
            pingChipLabel(conn)
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 28, minHeight: 28)
                .padding(.horizontal, 10)
                .background(Theme.Palette.fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(pingState[conn.id] == .pinging || checkState[conn.id] == .checking)
        .accessibilityLabel(L10n.pingButtonA11y.localized())
        // #258 was: .simultaneousGesture(LongPressGesture(...) { runCheckReady(conn) })
        // — removed; "Check time-to-ready" is a visible item in the overflow menu.
    }

    /// Chip content: a #242 time-to-ready result (stopwatch) takes precedence over
    /// the #234 latency state; otherwise the bolt ping chip.
    @ViewBuilder
    private func pingChipLabel(_ conn: ConnectionRecord) -> some View {
        switch checkState[conn.id] {
        case .checking:
            ProgressView().controlSize(.mini)
        case .done(.success(let ms)):
            HStack(spacing: 3) {
                Image(systemName: "stopwatch")
                Text("\(ms) ms").monospacedDigit()
            }
            .foregroundStyle(Theme.Palette.accent)
        case .done(.failure):
            Image(systemName: "stopwatch").foregroundStyle(Theme.Palette.red)
        case nil:
            switch pingState[conn.id] {
            case .pinging:
                ProgressView().controlSize(.mini)
            case .done(.success(let ms)):
                Text("\(ms) ms").foregroundStyle(Self.latencyColor(ms))
            case .done(.failure):
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(Theme.Palette.red)
            case nil:
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private func runPing(_ conn: ConnectionRecord) {
        guard pingState[conn.id] != .pinging else { return }
        checkState[conn.id] = nil   // #242: a fresh ping clears any ready-check overlay
        pingState[conn.id] = .pinging
        Task {
            let outcome = await tunnel.ping(conn.details)
            pingState[conn.id] = .done(outcome)
            switch outcome {
            case .success(let ms):
                LogStore.shared.log(.connection, L10n.pingResult_fmt.formatted(conn.displayName, ms))
            case .failure(let msg):
                LogStore.shared.log(.connection, L10n.pingFailedLog_fmt.formatted(conn.displayName, msg))
            }
        }
    }

    /// #242: isolated time-to-ready (WebRTC startup) check; result overlays the
    /// ping chip with a stopwatch. Triggered from the overflow menu.
    private func runCheckReady(_ conn: ConnectionRecord) {
        guard checkState[conn.id] != .checking else { return }
        checkState[conn.id] = .checking
        Task {
            let outcome = await tunnel.checkReady(conn.details)
            checkState[conn.id] = .done(outcome)
            switch outcome {
            case .success(let ms):
                LogStore.shared.log(.connection, L10n.checkReadyResult_fmt.formatted(conn.displayName, ms))
            case .failure(let msg):
                LogStore.shared.log(.connection, L10n.checkReadyFailedLog_fmt.formatted(conn.displayName, msg))
            }
        }
    }

    /// Green / orange / red thresholds for a SOCKS round-trip in milliseconds.
    private static func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<150:  return Theme.Palette.green
        case ..<400:  return Theme.Palette.orange
        default:      return Theme.Palette.red
        }
    }

    // MARK: Share connection sheet

    // #258: explanation + mono URI block (OlcCard) + three equal secondary actions.
    @ViewBuilder
    private func shareConnectionSheet(_ conn: ConnectionRecord) -> some View {
        let uri = Self.uriOf(conn)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.shareConnectionExplanation.localized())
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textSecondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.shareConnectionURIHeader.localized())
                            .tracking(0.6)
                            .font(Theme.Typography.sectionHeader)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        OlcCard {
                            Text(uri)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    VStack(spacing: 8) {
                        OlcButton(L10n.copyURIAction.localized(), systemImage: "doc.on.doc",
                                  role: .secondary, fillWidth: true) {
                            UIPasteboard.general.string = uri
                            shareConn = nil
                            LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
                        }
                        // ShareLink styled to match OlcButton(.secondary).
                        ShareLink(item: uri, subject: Text(conn.displayName)) {
                            Label(L10n.shareAction.localized(), systemImage: "square.and.arrow.up")
                                .font(Theme.Typography.button)
                                .foregroundStyle(Theme.Palette.accent)
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Metrics.controlHeight)
                                .background(Theme.Palette.fill,
                                            in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
                        }
                        OlcButton(L10n.actionQR.localized(), systemImage: "qrcode",
                                  role: .secondary, fillWidth: true) {
                            pendingQRConn = conn
                            shareConn = nil
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(L10n.shareConnectionTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { shareConn = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.closeAction.localized())
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// #262: `olcCardRow()` now lives in DesignSystem.swift (shared with ServersView).
