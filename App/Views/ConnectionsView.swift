import SwiftUI

// MARK: - ConnectionsView
//
// Shadowrocket-style layout, top to bottom:
//
//   1. Global toggle    — big on/off that connects the primary server
//                         and shows which server is selected.
//   2. Routing          — picker for how traffic is split (today: only
//                         "All through tunnel"; future: direct / rules / scene).
//   3. IP check         — runs direct or via tunnel depending on state.
//   4. Speed test       — same routing logic as IP check.
//   5. Server list      — grouped by `groupName`. Tap a row to mark it as
//                         primary (gold star). Pencil opens the edit sheet.
//
// "Primary" semantics:
//   - One connection at a time can be primary. With a single saved server
//     it is implicitly primary even if primaryID is nil.
//   - The global toggle always acts on the primary.
//   - Tapping a non-primary row switches the primary; toggle then needs
//     to be flipped to actually connect.

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
    @State private var ipCheckTime    : Date?

    /// Per-row ping state, keyed by connection id. Absent = never pinged.
    @State private var pingState      : [UUID: PingRowState] = [:]

    /// Transient state of the per-row latency probe (#234).
    private enum PingRowState: Equatable {
        case pinging
        case done(PingOutcome)
    }

    /// Per-row time-to-ready check state (#242). When present it overlays the
    /// ping chip with a stopwatch result; a re-ping (tap) clears it.
    @State private var checkState     : [UUID: CheckRowState] = [:]

    private enum CheckRowState: Equatable {
        case checking
        case done(PingOutcome)
    }

    private var routingMode: RoutingMode {
        RoutingMode(rawValue: routingRaw) ?? .allTunnel
    }

    private var currentMode: RouteMode {
        tunnel.state.isConnected ? .tunnel : .direct
    }

    var body: some View {
        NavigationStack {
            List {
                globalSection
                routingSection
                ipSection
                speedSection
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
                                Button(L10n.actionDone.localized()) {
                                    qrConn = nil
                                }
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

    // MARK: Share connection sheet

    @ViewBuilder
    private func shareConnectionSheet(_ conn: ConnectionRecord) -> some View {
        let uri = Self.uriOf(conn)
        NavigationStack {
            List {
                Section {
                    Text(L10n.shareConnectionExplanation.localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.shareConnectionURIHeader.localized()) {
                    Text(uri)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }

                Section {
                    Button {
                        UIPasteboard.general.string = uri
                        shareConn = nil
                        LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
                    } label: {
                        Label(L10n.copyURIAction.localized(), systemImage: "doc.on.doc")
                    }

                    ShareLink(item: uri, subject: Text(conn.displayName)) {
                        Label(L10n.shareAction.localized(), systemImage: "square.and.arrow.up")
                    }

                    Button {
                        pendingQRConn = conn
                        shareConn = nil
                    } label: {
                        Label(L10n.actionQR.localized(), systemImage: "qrcode")
                    }
                }
            }
            .navigationTitle(L10n.shareConnectionTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.actionDone.localized()) { shareConn = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 1. Global toggle

    private var globalSection: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tunnel.state.isConnected
                         ? L10n.stateConnected.localized()
                         : L10n.stateDisconnected.localized())
                        .font(.headline)
                        .foregroundStyle(tunnel.state.isConnected ? .green : .primary)
                    if let p = store.primary {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Image(systemName: "server.rack")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(p.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(p.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text(L10n.emptyNoConnectionsHint.localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                if tunnel.state.isConnecting {
                    ProgressView()
                }

                Toggle("", isOn: globalToggleBinding)
                    .labelsHidden()
                    .disabled(store.primary == nil || tunnel.state.isConnecting)
                    .scaleEffect(1.1)
            }
            .padding(.vertical, 4)

            if tunnel.state.isConnected {
                Text(L10n.socksProxyAddr_fmt.formatted(String(SettingsStore.shared.socksPort)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if case .failed(let msg) = tunnel.state {
                HStack(alignment: .top, spacing: 8) {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer(minLength: 4)
                    if let p = store.primary {
                        Button(L10n.actionRetry.localized()) {
                            tunnel.connect(record: p)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.red)
                    }
                }
            }
        }
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
    //
    // Single-line row: label on the left, current value on the right via
    // an inline Menu. Keeps the section compact while preserving the
    // ability to pick between modes once we add more options.

    private var routingSection: some View {
        Section(L10n.routingHeader.localized()) {
            HStack {
                Text(L10n.typeField.localized())
                Spacer()
                Menu {
                    ForEach(RoutingMode.allCases) { mode in
                        Button(mode.title) {
                            let prev = routingMode
                            routingRaw = mode.rawValue
                            if prev != mode {
                                LogStore.shared.log(.connection,
                                    "↻ routing mode: \(prev.title) → \(mode.title)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(routingMode.title)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: 3. IP check
    //
    // Compact: just service → IP rows (no route badge — routing policy is
    // already visible in the Routing section above).
    //
    // Collapsed view: when all sources return the same IP, show a single
    // green "✓ <ip> (N sources)" row.  When IPs differ, show each row with
    // a red ⚠️ warning above to alert the user of a possible DNS leak.

    private var ipCheckCollapsed: Bool {
        let ips = ipCheck.results.compactMap { $0.ip }
        guard ips.count >= 2 else { return false }
        return Set(ips).count == 1
    }

    private var ipCheckSummaryIP: String? {
        ipCheck.results.compactMap { $0.ip }.first
    }

    private var ipCheckHasResults: Bool {
        ipCheck.results.contains { $0.ip != nil || $0.error != nil }
    }

    private var ipCheckAllDone: Bool {
        !ipCheck.results.isEmpty && ipCheck.results.allSatisfy { $0.ip != nil || $0.error != nil }
    }

    private var ipSection: some View {
        Section {
            if ipCheck.isChecking {
                HStack {
                    ProgressView()
                        .padding(.trailing, 6)
                    Text(L10n.ipChecking.localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !ipCheckHasResults {
                Text(L10n.ipNotChecked.localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if ipCheckCollapsed, let ip = ipCheckSummaryIP {
                HStack {
                    Text(L10n.ipSourcesAgree_fmt.formatted(ip, ipCheck.results.filter { $0.ip != nil }.count))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                    Spacer()
                }
            } else {
                if ipCheckAllDone {
                    let uniqueIPs = Set(ipCheck.results.compactMap { $0.ip })
                    if uniqueIPs.count > 1 {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text(L10n.ipDnsLeak.localized())
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                ForEach(ipCheck.results) { r in
                    HStack {
                        Text(r.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let ip = r.ip {
                            Text(ip).font(.system(.caption, design: .monospaced))
                        } else if let err = r.error {
                            Text(err).font(.caption2).foregroundStyle(.red)
                                .lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Button {
                    Task {
                        await ipCheck.checkAll(via: currentMode)
                        ipCheckTime = Date()
                    }
                } label: {
                    Label(L10n.ipCheckRun.localized(), systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .disabled(ipCheck.isChecking)
                Spacer()
                if ipCheck.isChecking { ProgressView() }
                else if let t = ipCheckTime {
                    Text(L10n.ipLastCheck_fmt.formatted(Self.shortTimeFormatter.string(from: t)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text(L10n.ipCheckTitle.localized())
        }
    }

    // MARK: 4. Speed test
    //
    // One-line indicators: ping · download · upload with units inline.
    // Service name lives in a small grey caption below the values so the
    // user can see which endpoint produced the numbers without taking
    // multiple rows of vertical space.

    private var speedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 14) {
                    let pingStr = speed.lastResult?.pingMs.map { String(format: "%.0f ms", $0) }
                    let dlStr   = speed.lastResult?.downloadMbps.map { String(format: "%.1f Mbps", $0) }
                    let ulStr   = speed.lastResult?.uploadMbps.map { String(format: "%.1f Mbps", $0) }
                    speedMetric("Ping", pingStr, accessibilityLabel: "Ping: \(pingStr ?? "—")")
                    speedMetric("DL",   dlStr,   accessibilityLabel: "Download: \(dlStr ?? "—")")
                    speedMetric("UL",   ulStr,   accessibilityLabel: "Upload: \(ulStr ?? "—")")
                    Spacer()
                }
                Text(speed.lastResult?.service ?? "speed.cloudflare.com")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    Task { await speed.run(via: currentMode) }
                } label: {
                    Label(L10n.speedTestRun.localized(), systemImage: "speedometer")
                }
                .buttonStyle(.bordered)
                .disabled(speed.isTesting)
                Spacer()
                if speed.isTesting { ProgressView() }
            }
        } header: {
            Text(L10n.speedTestTitle.localized())
        }
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Reassembles the original `olcrtc://` URI for sharing. The context
    /// menu on a server row exposes this to the user via Copy + ShareLink.
    private static func uriOf(_ conn: ConnectionRecord) -> String {
        switch conn.details {
        case .olcrtc(let p): return OlcrtcURI.encode(p)
        }
    }

    private func speedMetric(_ label: String, _ value: String?, accessibilityLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value ?? "—")
                .font(.system(.callout, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: 5. Server list (grouped)

    private var serversSection: some View {
        Group {
            if store.connections.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "network")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text(L10n.emptyNoConnections.localized())
                            .font(.headline)
                        Text(L10n.emptyNoConnectionsHint.localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
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
            // Primary marker on the left
            ZStack {
                Circle()
                    .strokeBorder(isPrimary ? Color.yellow : Color.secondary.opacity(0.3),
                                  lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                if isPrimary {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(conn.displayName)
                    if isPrimary {
                        Text(L10n.primaryRoleMain.localized())
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                Text(conn.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            pingButton(conn)

            // DO NOT REMOVE — primary quick-edit affordance; also in context menu but less discoverable there.
            Button { editConn = conn } label: {
                Image(systemName: "pencil.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.setPrimary(conn.id)
        }
        .contextMenu {
            if store.primary?.id != conn.id {
                Button {
                    store.setPrimary(conn.id)
                    tunnel.connect(record: conn)
                } label: {
                    Label(L10n.actionConnect.localized(), systemImage: "play.fill")
                }
            }
            Button {
                runPing(conn)
            } label: {
                Label(L10n.pingButtonA11y.localized(), systemImage: "bolt.horizontal.circle")
            }
            Button {
                runCheckReady(conn)
            } label: {
                Label(L10n.checkReadyA11y.localized(), systemImage: "stopwatch")
            }
            Button {
                shareConn = conn
            } label: {
                Label(L10n.shareConnectionTitle.localized(), systemImage: "square.and.arrow.up")
            }
            Button {
                let uri = Self.uriOf(conn)
                UIPasteboard.general.string = uri
                LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
            } label: {
                Label(L10n.copyURIAction.localized(), systemImage: "doc.on.doc")
            }
            Button {
                qrConn = conn
            } label: {
                Label(L10n.actionQR.localized(), systemImage: "qrcode")
            }
            Divider()
            Button {
                editConn = conn
            } label: {
                Label(L10n.edit.localized(), systemImage: "pencil")
            }
        }
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

    // MARK: Per-connection ping (#234)

    /// Trailing-edge latency affordance: a bolt icon that becomes a spinner
    /// while probing, then a colored "<n> ms" chip (or a red bolt on failure).
    /// Tapping re-runs the probe. Measures latency via an isolated MobilePing
    /// client, so it works whether or not the main tunnel is connected.
    @ViewBuilder
    private func pingButton(_ conn: ConnectionRecord) -> some View {
        Button {
            runPing(conn)
        } label: {
            pingChipLabel(conn)
        }
        .buttonStyle(.plain)
        .disabled(pingState[conn.id] == .pinging || checkState[conn.id] == .checking)
        .accessibilityLabel(L10n.pingButtonA11y.localized())
        .accessibilityHint(L10n.checkReadyA11y.localized())
        // #242: long-press runs the time-to-ready check (also in the context menu).
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in runCheckReady(conn) }
        )
    }

    /// Chip content: a #242 time-to-ready result (stopwatch) takes precedence
    /// over the #234 latency state when present; otherwise the bolt ping chip.
    @ViewBuilder
    private func pingChipLabel(_ conn: ConnectionRecord) -> some View {
        switch checkState[conn.id] {
        case .checking:
            ProgressView().controlSize(.mini)
        case .done(.success(let ms)):
            HStack(spacing: 2) {
                Image(systemName: "stopwatch")
                Text("\(ms) ms").monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.blue)
        case .done(.failure):
            Image(systemName: "stopwatch").foregroundStyle(.red)
        case nil:
            switch pingState[conn.id] {
            case .pinging:
                ProgressView().controlSize(.mini)
            case .done(.success(let ms)):
                Text("\(ms) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Self.latencyColor(ms))
            case .done(.failure):
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(.red)
            case nil:
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary)
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
    /// ping chip with a stopwatch. Triggered by long-press or the context menu.
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
    /// A WebRTC-tunnelled proxy adds latency over a raw link, so the bands are
    /// deliberately looser than a bare-TCP ping would use.
    private static func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<150:  return .green
        case ..<400:  return .orange
        default:      return .red
        }
    }
}
