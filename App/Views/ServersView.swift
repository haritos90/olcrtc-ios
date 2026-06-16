import SwiftUI

// MARK: - ServersView
//
// Third tab. Manages SSH credentials for VPS hosts where we can install /
// uninstall olcrtc, plus triggers those operations from the device.
//
// #258: SINGLE-SOURCE display model (replaces the old dual-source
// `statusIconInfo`, which read `provisioner.status` + per-host `readiness`
// together and wrote optimistic base states mid-flight — the cause of the
// "status jumps"). A host now shows exactly ONE of:
//   • .base(HostBase)            — what the server IS; set ONLY by a confirmed probe
//   • .running(op, phase, note)  — what we're DOING; steady amber, phases advance
//                                  forward only, never touches base state
//   • .failed(op, phase, msg)    — an op threw; shown over the last base, with Retry
// The dot stays amber for the whole operation and changes colour exactly once,
// at the terminal probe result (`.animation(.easeInOut, value: display)`).
//
// Status / phase strings here are hardcoded English to match this file's existing
// convention (the old statusIconInfo did the same); menu/action labels reuse the
// existing L10n cases. Promoting these to L10n is a separate cleanup.

struct ServersView: View {
    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore
    /// #339: "Container logs" routes to the Logs tab through this app-level
    /// router (MainTabView switches the tab, LogsView consumes).
    /// #334 was: `let logsRouter` — now observed so the card reacts to
    /// `fetchingHostID` and shows a busy indicator during a container-log fetch.
    @ObservedObject var logsRouter: LogsRouter
    /// Per-tab lifecycle, NOT a shared singleton — intentional split from
    /// `TunnelManager.shared` / `SettingsStore.shared` / `LogStore.shared`.
    @StateObject  private var provisioner = Provisioner()

    @State private var showAdd        = false
    @State private var editHost       : ServerHost?
    @State private var installFor     : ServerHost?
    @State private var reconfigureFor : ServerHost?
    // #339 was: logsPayload (ContainerLogsPayload?) — the container-logs sheet
    // is gone; the action routes to the Logs tab instead.
    // #258 was: readiness[id] + activeHostID (two competing display sources).
    // Now a single per-host display state; base is only ever set from a probe.
    @State private var display        : [UUID: HostDisplay] = [:]
    @State private var vpsStats       : [UUID: SSHRunner.VPSStats] = [:]
    @State private var pingLatencies  : [UUID: Double?] = [:]   // ms, nil=unreachable, absent=not pinged
    // #374: when each host was last probed, so the periodic sweep only re-pings
    // hosts whose last ping is older than the interval (instead of every host
    // every tick). Absent → never pinged → due immediately.
    @State private var lastPing       : [UUID: Date] = [:]
    @State private var scanFor        : ServerHost?
    @State private var foundContainers: [SSHRunner.FoundContainer] = []
    @State private var shareConn      : ConnectionRecord?   // #304: share the host's linked connection
    @State private var shareFullAccess: FullAccessShareRequest?   // #135: full-access (SSH) share
    @State private var alertText           : String?
    @State private var removeHost          : ServerHost?
    @State private var uninstallConfirmHost    : ServerHost?
    @State private var deepUninstallConfirmHost: ServerHost?
    @State private var rebootConfirmHost       : ServerHost?
    // #303: confirm before recovering/adding a ConnectionRecord from an
    // already-installed-but-unlinked host (#302 auto-detect with no
    // lastConnectionID).
    @State private var recoverConfirmHost      : ServerHost?
    // #314: fallback when #303 recovery finds server.yaml unreadable or
    // unparseable — confirm before rotating ~/.olcrtc_key (destructive for
    // every other client of that server).
    @State private var rotateKeyConfirmHost    : ServerHost?
    // #374 was: pingTimer (Timer?) — a repeating Timer that re-pinged EVERY
    // host every tick, even mid-op. Replaced by a structured `.task` sweep loop
    // (autoPingLoop) tied to the view lifecycle, which cancels cleanly on
    // disappear (no manual invalidate needed) and only re-pings stale hosts.

    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        NavigationStack {
            List {
                matrixSection

                if serverStore.hosts.isEmpty {
                    emptyState
                } else {
                    ForEach(serverStore.hosts) { host in
                        hostCard(host)
                    }
                    .onDelete { serverStore.remove(at: $0) }
                }
            }
            .navigationTitle(L10n.serversTitle.localized())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // #359: icon-only "+" needs an a11y label (reused newServerTitle).
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(L10n.newServerTitle.localized())
                }
            }
            // #374: structured sweep loop tied to the view lifecycle — SwiftUI
            // cancels it when the view disappears, replacing the old
            // onAppear-start / onDisappear-invalidate Timer pair.
            .task { await autoPingLoop() }
            // #258: route the provisioner's progress stream into the running host's
            // phase/subtitle ONLY — never the base state or the dot colour.
            .onChange(of: provisioner.status) { _, status in
                guard case .running(let msg) = status else { return }
                advancePhase(note: msg)
            }
            .sheet(isPresented: $showAdd) {
                // #295: pass every existing label so the sheet can reject a
                // duplicate (case-insensitive / sanitised-prefix) name.
                AddServerHostView(otherLabels: serverStore.hosts.map(\.label)) { host, pw in
                    serverStore.add(host, password: pw)
                }
            }
            .sheet(item: $editHost) { host in
                AddServerHostView(existing: host,
                                  existingPassword: serverStore.password(for: host),
                                  otherLabels: serverStore.hosts.filter { $0.id != host.id }.map(\.label)) { updated, pw in
                    serverStore.update(updated, password: pw.isEmpty ? nil : pw)
                }
            }
            .sheet(item: $installFor) { host in
                InstallOptionsView { options in
                    Task { await install(host, options: options) }
                }
            }
            .sheet(item: $reconfigureFor) { host in
                ReconfigureOptionsView { options in
                    Task { await reconfigure(host, options: options) }
                }
            }
            // #339 was: .sheet(item: $logsPayload) { ContainerLogsView(payload:) }
            .sheet(item: $scanFor) { host in
                containerScanSheet(host: host)
            }
            // #304: "Share connection" moved here from the Connections tab.
            .sheet(item: $shareConn) { conn in
                ShareConnectionView(conn: conn)
            }
            // #135: full-access (co-admin) share — the same sheet, with the SSH
            // payload that unlocks the destructive opt-in section.
            .sheet(item: $shareFullAccess) { req in
                ShareConnectionView(conn: req.conn, fullAccess: req.payload)
            }
            .alert(L10n.okPrompt.localized(), isPresented: Binding(
                get: { alertText != nil },
                set: { if !$0 { alertText = nil } }
            )) {
                Button(L10n.ok.localized()) { alertText = nil }
            } message: {
                Text(alertText ?? "")
            }
            .confirmationDialog(
                removeHost.map { L10n.removeHostConfirmTitle.formatted($0.label) } ?? "",
                isPresented: Binding(
                    get: { removeHost != nil },
                    set: { if !$0 { removeHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: removeHost
            ) { host in
                Button(L10n.actionRemoveFromList.localized(), role: .destructive) {
                    removeFromList(host)
                    removeHost = nil
                }
                Button(L10n.cancel.localized(), role: .cancel) { removeHost = nil }
            } message: { _ in
                Text(L10n.removeHostConfirmMessage.localized())
            }
            .confirmationDialog(
                L10n.uninstallConfirmTitle.localized(),
                isPresented: Binding(
                    get: { uninstallConfirmHost != nil },
                    set: { if !$0 { uninstallConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: uninstallConfirmHost
            ) { host in
                Button(L10n.actionUninstall.localized(), role: .destructive) {
                    uninstallConfirmHost = nil
                    Task { await uninstall(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { uninstallConfirmHost = nil }
            } message: { _ in
                Text(L10n.uninstallConfirmBody.localized())
            }
            .confirmationDialog(
                L10n.actionDeepUninstall.localized(),
                isPresented: Binding(
                    get: { deepUninstallConfirmHost != nil },
                    set: { if !$0 { deepUninstallConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: deepUninstallConfirmHost
            ) { host in
                Button(L10n.actionDeepUninstall.localized(), role: .destructive) {
                    deepUninstallConfirmHost = nil
                    Task { await deepUninstall(host, removeImage: false) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { deepUninstallConfirmHost = nil }
            } message: { _ in
                Text(L10n.deepUninstallConfirmBody.localized())
            }
            .confirmationDialog(
                L10n.rebootConfirmTitle.localized(),
                isPresented: Binding(
                    get: { rebootConfirmHost != nil },
                    set: { if !$0 { rebootConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: rebootConfirmHost
            ) { host in
                Button(L10n.actionReboot.localized(), role: .destructive) {
                    rebootConfirmHost = nil
                    Task { await reboot(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { rebootConfirmHost = nil }
            } message: { _ in
                Text(L10n.rebootConfirmBody.localized())
            }
            // #303: recover/add a ConnectionRecord from this host's deployed
            // server.yaml — read-only on the server, only adds locally.
            .confirmationDialog(
                L10n.recoverConfirmTitle.localized(),
                isPresented: Binding(
                    get: { recoverConfirmHost != nil },
                    set: { if !$0 { recoverConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: recoverConfirmHost
            ) { host in
                Button(L10n.recoverConfirmAction.localized()) {
                    recoverConfirmHost = nil
                    Task { await recoverConnection(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { recoverConfirmHost = nil }
            } message: { _ in
                Text(L10n.recoverConfirmBody.localized())
            }
            // #314: #303's fallback branch — server.yaml was unreadable or
            // unparseable, so offer to generate a new key (rotate ~/.olcrtc_key,
            // repair server.yaml, restart) instead of just failing. Destructive:
            // the new key cuts off every other client of this server.
            .confirmationDialog(
                L10n.rotateKeyConfirmTitle.localized(),
                isPresented: Binding(
                    get: { rotateKeyConfirmHost != nil },
                    set: { if !$0 { rotateKeyConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: rotateKeyConfirmHost
            ) { host in
                Button(L10n.rotateKeyConfirmAction.localized(), role: .destructive) {
                    rotateKeyConfirmHost = nil
                    Task { await rotateKey(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { rotateKeyConfirmHost = nil }
            } message: { _ in
                Text(L10n.rotateKeyConfirmBody.localized())
            }
        }
    }

    private func removeFromList(_ host: ServerHost) {
        if let idx = serverStore.hosts.firstIndex(where: { $0.id == host.id }) {
            serverStore.remove(at: IndexSet([idx]))
        }
    }

    // MARK: Compatibility matrix

    private var matrixSection: some View {
        Section {
            OlcCard { MatrixView() }
                .olcCardRow()
        } header: {
            Text(L10n.carrierTransportMatrix.localized())
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        Section {
            // #258: shared OlcEmptyState with a primary CTA (was a bare VStack).
            OlcEmptyState(systemImage: "externaldrive.connected.to.line.below",
                          title: L10n.emptyNoServers.localized(),
                          hint: L10n.emptyNoServersHint.localized(),
                          ctaTitle: L10n.newServerTitle.localized()) {
                showAdd = true
            }
            .olcCardRow()
        }
    }

    // MARK: Display-state helpers (single source of truth)

    /// The host's current display state. Before any probe, seed a conservative
    /// base from persisted data: a known container → `.stopped` (so Start/Stop and
    /// the metrics surface, and we never offer a reinstall by mistake); otherwise
    /// `.unknown` ("tap Check"). Never asserts a running container without a probe.
    private func displayState(_ host: ServerHost) -> HostDisplay {
        display[host.id] ?? .base(.seed(lastContainerName: host.lastContainerName))
    }

    /// The base under whatever is currently shown (running/failed keep the base
    /// they started from). Drives the menu / button shape.
    private func currentBase(_ host: ServerHost) -> HostBase { displayState(host).base }

    private func hasContainer(_ host: ServerHost) -> Bool { currentBase(host).hasContainer }
    private func isRunning(_ host: ServerHost)   -> Bool { currentBase(host) == .running }

    /// #304: the ConnectionRecord this host installed/owns (by `lastConnectionID`),
    /// if still present — drives the "Share connection" item on the server card.
    private func linkedConnection(_ host: ServerHost) -> ConnectionRecord? {
        guard let id = host.lastConnectionID else { return nil }
        return connections.connections.first { $0.id == id }
    }

    /// #135: builds the full-access (co-admin) share request for a host + its
    /// linked connection — the connection URI plus the SSH host/port/login and
    /// the password read live from the Keychain (ServerHostStore → KeychainHelper).
    /// Returns nil when no password is stored, so the destructive item silently
    /// no-ops rather than sharing a credential-less, useless blob.
    private func fullAccessRequest(_ host: ServerHost, conn: ConnectionRecord) -> FullAccessShareRequest? {
        guard let password = serverStore.password(for: host) else { return nil }
        let uri: String
        switch conn.details {
        case .olcrtc(let p): uri = OlcrtcURI.encode(p)
        }
        let payload = FullAccessShare(
            uri: uri,
            label: host.label,
            sshHost: host.host,
            sshPort: host.port,
            sshUsername: host.username,
            sshPassword: password)
        return FullAccessShareRequest(conn: conn, payload: payload)
    }

    /// Any host mid-operation. Operations are serialized (one provisioner), so we
    /// disable every card's actions while one runs — this also keeps `runningHostID`
    /// unambiguous for phase routing.
    private var anyBusy: Bool { display.values.contains { $0.isRunning } }
    private var actionsDisabled: Bool { anyBusy || provisioner.status.isRunning }
    private var runningHostID: UUID? { display.first { $0.value.isRunning }?.key }

    // MARK: The ONE operation driver
    //
    // Sets `.running`, lets `work` do the SSH work + the confirming probe (the
    // ONLY thing that returns a base), then makes a SINGLE terminal assignment:
    // `.base` on success, `.failed` on throw. `work` must not write `display`.

    private func run(_ op: HostOp, on host: ServerHost,
                     _ work: @escaping (_ password: String) async throws -> HostBase?) async {
        guard !anyBusy else { return }
        let prev = currentBase(host)
        display[host.id] = .start(op, from: prev)

        guard let pw = password(for: host) else {
            withAnimation(.easeInOut(duration: 0.35)) {
                display[host.id] = HostDisplay.start(op, from: prev)
                    .failed(message: L10n.alertPasswordMissingShort.localized())
            }
            return
        }

        do {
            let resolved = try await work(pw)
            // One terminal change — the probe result is authoritative (no optimism);
            // else the op's nominal target; else keep the previous base (e.g. reboot).
            let base = HostDisplay.terminalBase(op: op, probed: resolved, previous: prev)
            withAnimation(.easeInOut(duration: 0.35)) { display[host.id] = .base(base) }
        } catch {
            let current = display[host.id] ?? .start(op, from: prev)
            withAnimation(.easeInOut(duration: 0.35)) {
                display[host.id] = current.failed(message: error.localizedDescription)
            }
        }
    }

    /// Maps a provisioner progress message onto the running host: phase forward
    /// (monotonic, capped) + subtitle = the live message. Never touches base/dot.
    private func advancePhase(note: String) {
        guard let id = runningHostID else { return }
        display[id] = display[id]?.advanced(note: note)
    }

    /// Re-runs the failed op. Returns to the previous base first, then dispatches
    /// (sheet-driven ops reopen their sheet so the user reconfirms options).
    private func retry(_ op: HostOp, on host: ServerHost) async {
        if let restored = display[host.id]?.retryBase() { display[host.id] = restored }
        switch op {
        case .check:         await checkServer(host)
        case .start:         await startContainer(host)
        case .stop:          await stop(host)
        case .update:        await update(host)
        case .reboot:        await reboot(host)
        case .install:       installFor = host
        case .reconfigure:   reconfigureFor = host
        case .uninstall:     uninstallConfirmHost = host
        case .deepUninstall: deepUninstallConfirmHost = host
        }
    }

    // MARK: Auto-ping
    //
    // #374: a single structured sweep loop replaces the old repeating Timer
    // that re-pinged EVERY host every tick (even mid-SSH-op, even when nothing
    // had changed). Each pass:
    //   • does an immediate first ping of any never-pinged host;
    //   • when auto-ping is on, wakes every `interval` and re-pings ONLY hosts
    //     whose last ping is older than the interval (skipping fresh ones);
    //   • skips the periodic sweep entirely while an op is in flight
    //     (actionsDisabled) — checkServer already pings the host it touches;
    //   • staggers the per-host probes by a small delay so they don't all fire
    //     on the same instant.
    // The loop runs inside `.task`, so SwiftUI cancels it on disappear.

    /// Small per-host gap so a fleet doesn't fire every probe on one tick (#374).
    private static let pingStaggerSeconds: Double = 0.4

    private func autoPingLoop() async {
        // Initial pass: ping every host that's never been pinged.
        await pingDueHosts(force: true)

        // Periodic sweeps only when enabled and a positive interval is set.
        while !Task.isCancelled {
            guard settings.vpsAutoPingEnabled, settings.vpsAutoPingInterval > 0 else { return }
            let interval = TimeInterval(settings.vpsAutoPingInterval)
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return   // cancelled while sleeping
            }
            // Don't sweep on top of an in-flight SSH op — it would queue probes
            // against a host we're already talking to, and nothing's changed.
            guard !actionsDisabled else { continue }
            await pingDueHosts(force: false)
        }
    }

    /// Pings every host whose ping is stale (older than the configured
    /// interval) — or, with `force`, every host not yet pinged. Staggered.
    private func pingDueHosts(force: Bool) async {
        let interval = TimeInterval(settings.vpsAutoPingInterval)
        let now = Date()
        let due = serverStore.hosts.filter { host in
            guard let last = lastPing[host.id] else { return true }   // never pinged → due
            return force ? false : now.timeIntervalSince(last) >= interval
        }
        for (i, host) in due.enumerated() {
            if i > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.pingStaggerSeconds * 1_000_000_000))
                } catch {
                    return   // cancelled mid-stagger
                }
            }
            if Task.isCancelled { return }
            await doPing(host)
        }
    }

    private func doPing(_ host: ServerHost) async {
        let result = await NetPing.tcp(host: host.host, port: UInt16(host.port), timeout: 5)
        pingLatencies[host.id] = result.success ? result.ms : nil
        lastPing[host.id] = Date()   // #374: record so the sweep can skip fresh hosts
    }

    // MARK: Host card

    private func hostCard(_ host: ServerHost) -> some View {
        let state = displayState(host)
        return Section {
            OlcCard {
                VStack(alignment: .leading, spacing: 12) {
                    // Header: label + connection + the single complete action menu
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.label)
                                .font(.headline)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            // #337: mask the host for display when screenshot-safe
                            // mode is on (IP literals → •••.•••.•••.x; hostnames
                            // pass through). Display-only: host.host stays real.
                            Text("\(host.username)@\(IPMask.display(host.host, masked: settings.maskIPs)):\(String(host.port))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        OlcOverflowMenu(items: menuItems(host))
                            .disabled(actionsDisabled)
                    }

                    // #334: container-log fetch runs on the Logs tab (#339), so it
                    // isn't a HostOp and never reaches `statusRegion`. Surface its
                    // progress here from the router's published in-flight host.
                    containerLogBusyStrip(host)

                    statusRegion(host, state: state)

                    // #341 was: metrics only when idle on a container-bearing
                    // base — the card changed height with every state flip.
                    // Fixed footprint now: the strip is ALWAYS rendered ("—"
                    // placeholders, dimmed while an op runs).
                    metricsStrip(host, state: state)

                    actionBar(host, state: state)
                }
                .animation(.easeInOut(duration: 0.35), value: state)
                // #334: fade the container-log busy strip in/out smoothly.
                .animation(.easeInOut(duration: 0.35), value: logsRouter.fetchingHostID)
            }
            .olcCardRow()
        }
    }

    /// #334: a compact busy row shown only while THIS host's container-log
    /// fetch is in flight (on the Logs tab). Reuses the `.progress` status tone
    /// + OlcProgressBar, mirroring an in-card operation. The `.transition` +
    /// the card's own animation (keyed on `fetchingHostID` below) keep it from
    /// snapping in — see #335 for the start-jank lesson.
    @ViewBuilder
    private func containerLogBusyStrip(_ host: ServerHost) -> some View {
        if logsRouter.fetchingHostID == host.id {
            VStack(alignment: .leading, spacing: 8) {
                OlcStatusPill(tone: .progress,
                              title: L10n.actionContainerLogs.localized(),
                              subtitle: L10n.logsPhaseReceiving.localized()) {
                    ProgressView().controlSize(.small)
                }
                OlcProgressBar(fraction: 1)   // indeterminate-ish: the fetch has no fraction here
            }
            .transition(.opacity)
        }
    }

    // Status region — exactly one of: operation / error / base.
    // #341: fixed-height container (≈58pt) so the pill / pill+bar / failed
    // pill swap never changes the card height; the existing `.animation`
    // crossfades the content.
    // #335: the pill is now ALWAYS rendered in the same top slot — only its
    // tone/title/subtitle change — and the progress bar lives in a fixed-height
    // slot BELOW it that just fades its opacity. Previously the `.running` case
    // wrapped the pill in its own VStack while `.base`/`.failed` rendered a bare
    // pill, so when the op started the crossfade animated the pill from one
    // vertical anchor to another, overlapping the text for ~0.5s. One stable
    // pill position kills the overlap.
    @ViewBuilder
    private func statusRegion(_ host: ServerHost, state: HostDisplay) -> some View {
        let bar = statusBarFraction(state)
        VStack(alignment: .leading, spacing: 8) {
            OlcStatusPill(tone: statusTone(state),
                          title: statusTitle(state),
                          subtitle: statusSubtitle(state)) {
                if state.isRunning { ProgressView().controlSize(.small) }
            }
            // #338 was: ProgressView(value:total:).tint(amber) — extracted into
            // the shared OlcProgressBar (also used by the Logs fetch). The slot
            // is always present (fixed 4pt) so the pill above never reflows when
            // the bar appears/disappears; opacity carries the transition (#335).
            OlcProgressBar(fraction: bar ?? 0)
                .opacity(bar == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
    }

    // #335: per-state pill content, split out so the ONE pill above can render
    // any state without changing its position.
    private func statusTone(_ state: HostDisplay) -> OlcStatusTone {
        switch state {
        case .running:        return .progress
        case .failed:         return .error
        case .base(let b):    return b.tone
        }
    }
    private func statusTitle(_ state: HostDisplay) -> String {
        switch state {
        case .running(let op, _, _, _): return "\(op.verb)…"
        case .failed(let op, _, _, _):  return L10n.vpsOpFailed_fmt.formatted(op.verb)
        case .base(let b):              return b.title
        }
    }
    private func statusSubtitle(_ state: HostDisplay) -> String {
        switch state {
        case .running(let op, let phase, let note, _):
            return "\(note) · \(min(phase + 1, op.stepCount))/\(op.stepCount)"
        case .failed(_, let phase, let message, _):
            return "\(phase.replacingOccurrences(of: "…", with: "")) · \(message)"
        case .base(let b):
            return b.subtitle
        }
    }
    /// The progress fraction while running; nil when the bar slot is empty.
    private func statusBarFraction(_ state: HostDisplay) -> Double? {
        guard case .running(let op, let phase, _, _) = state else { return nil }
        return Double(min(phase + 1, op.stepCount)) / Double(max(op.stepCount, 1))
    }

    // #341 was: metricsRow — a conditional 4×OlcMetric two-deck row (17pt mono).
    // Now a one-line always-rendered strip: PING 27ms · DISK 36/40G · RAM
    // 241/2048M · UP 11d, dimmed while an op runs.
    private func metricsStrip(_ host: ServerHost, state: HostDisplay) -> some View {
        let stats = vpsStats[host.id]
        // #408: drop the "·" separators and pack the stats closer. The separators
        // plus their padding ate roughly a third of the row, squeezing the values
        // until they truncated ("4.4/4…", "501/19…"); the uppercase-tertiary label
        // vs. mono-primary value contrast already delineates each stat without a
        // glyph between them. #408 was: HStack(spacing: 8) with a `statDot` between
        // every OlcMiniStat.
        return HStack(spacing: 12) {
            pingMiniStat(host)
            // #346: labels through L10n (ru = en for the abbreviations); units
            // like "G"/"M"/"d" inside the values stay English.
            OlcMiniStat(label: L10n.vpsStatDisk.localized(), value: Self.shortUsage(stats?.disk))
            OlcMiniStat(label: L10n.vpsStatRAM.localized(),  value: Self.shortUsage(stats?.ram))
            OlcMiniStat(label: L10n.vpsStatUp.localized(),   value: Self.shortUptime(stats?.uptime))
            Spacer(minLength: 0)
        }
        .opacity(state.isRunning ? 0.45 : 1)
    }

    private func pingMiniStat(_ host: ServerHost) -> OlcMiniStat {
        switch pingLatencies[host.id] {
        case .some(.some(let ms)):
            // #346: "Ping" label through L10n (ru = en); "ms" stays English.
            return OlcMiniStat(label: L10n.vpsStatPing.localized(), value: String(format: "%.0fms", ms),
                               tone: ms < 100 ? Theme.Palette.green
                                   : ms < 300 ? Theme.Palette.orange : Theme.Palette.red)
        case .some(.none):
            return OlcMiniStat(label: L10n.vpsStatPing.localized(), value: "✕", tone: Theme.Palette.red)
        case .none:
            return OlcMiniStat(label: L10n.vpsStatPing.localized(), value: "—", tone: Theme.Palette.textTertiary)
        }
    }

    /// #341: compact a `df`/`free` "36G/40G" pair to "36/40G" (shared unit
    /// suffix hoisted to the right side); mixed units stay as-is. Internal
    /// static so the unit tests can pin the edge cases.
    static func shortUsage(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let u0 = parts[0].last, let u1 = parts[1].last,
              u0 == u1, u0.isLetter else { return s }
        return "\(parts[0].dropLast())/\(parts[1])"
    }

    /// #341: compact the `uptime` tail — "3 days" → "3d", "35 min" → "35m";
    /// the "H:MM" (<1 day) form stays as-is.
    static func shortUptime(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return s.replacingOccurrences(of: " days", with: "d")
                .replacingOccurrences(of: " day",  with: "d")
                .replacingOccurrences(of: " min",  with: "m")
    }

    // Action bar — one contextual primary + three fixed icon-only quick
    // actions (#341: 44×44 tinted OlcIconButtons; was one antenna OlcButton).
    // Everything here is a subset of `menuItems`; nothing is card-exclusive.
    @ViewBuilder
    private func actionBar(_ host: ServerHost, state: HostDisplay) -> some View {
        HStack(spacing: 8) {
            primaryButton(host, state: state)
            OlcIconButton(systemImage: "antenna.radiowaves.left.and.right") {
                Task { await checkServer(host) }
            }
            .disabled(actionsDisabled)
            .accessibilityLabel(L10n.vpsCheckServer.localized())
            OlcIconButton(systemImage: "arrow.down.doc", tint: Theme.Palette.green) {
                logsRouter.request = .init(hostID: host.id, autofetch: true)   // #339 route
            }
            .disabled(actionsDisabled || !hasContainer(host))
            .accessibilityLabel(L10n.actionContainerLogs.localized())
            OlcIconButton(systemImage: "slider.horizontal.3", tint: Theme.Palette.orange) {
                reconfigureFor = host
            }
            .disabled(actionsDisabled || !hasContainer(host))
            .accessibilityLabel(L10n.actionChangeRoomTransport.localized())
        }
    }

    @ViewBuilder
    private func primaryButton(_ host: ServerHost, state: HostDisplay) -> some View {
        switch state {
        case .running:
            OlcButton(L10n.vpsWorking.localized(), role: .secondary, isBusy: true, fillWidth: true) {}
        case .failed(let op, _, _, _):
            OlcButton(L10n.actionRetry.localized(), systemImage: "arrow.clockwise",
                      role: .primary, fillWidth: true) {
                Task { await retry(op, on: host) }
            }
            .disabled(actionsDisabled)
        case .base(let b):
            if b.hasContainer {
                if b == .running {
                    OlcButton(L10n.actionStop.localized(), systemImage: "stop.fill",
                              role: .danger, fillWidth: true) {
                        Task { await stop(host) }
                    }
                    .disabled(actionsDisabled)
                } else {
                    OlcButton(L10n.actionStart.localized(), systemImage: "play.fill",
                              role: .primary, fillWidth: true) {
                        Task { await startContainer(host) }
                    }
                    .disabled(actionsDisabled)
                }
            } else {
                OlcButton(L10n.actionInstall.localized(), systemImage: "arrow.down.app",
                          role: .primary, fillWidth: true) {
                    installFor = host
                }
                .disabled(actionsDisabled)
            }
        }
    }

    // MARK: Overflow menu — the single COMPLETE action set
    //
    // #258: this is the source of truth. The card's primary + Check buttons are a
    // derived subset of these items (no more "MUST mirror card buttons" duplication).

    private func menuItems(_ host: ServerHost) -> [OlcMenuItem] {
        var items: [OlcMenuItem] = [
            .action(L10n.vpsCheckServer.localized(), systemImage: "antenna.radiowaves.left.and.right") {
                Task { await checkServer(host) }
            }
        ]

        if hasContainer(host) {
            if isRunning(host) {
                items.append(.action(L10n.actionStop.localized(), systemImage: "stop.fill", role: .destructive) {
                    Task { await stop(host) }
                })
            } else {
                items.append(.action(L10n.actionStart.localized(), systemImage: "play.fill") {
                    Task { await startContainer(host) }
                })
            }
            // #339 was: "Download container logs" → fetchLogs(host) + sheet.
            // Now routes to the Logs tab (Container category, this host) and
            // auto-starts the fetch there.
            items.append(.action(L10n.actionContainerLogs.localized(), systemImage: "arrow.down.doc") {
                logsRouter.request = .init(hostID: host.id, autofetch: true)
            })
            items.append(.action(L10n.actionChangeRoomTransport.localized(), systemImage: "slider.horizontal.3") {
                reconfigureFor = host
            })
            items.append(.action(L10n.actionUpdate.localized(), systemImage: "arrow.triangle.2.circlepath") {
                Task { await update(host) }
            })
            // #303: container is installed but no ConnectionRecord links to it —
            // surface the recovery action so the user can get a usable connection
            // without re-installing or losing the room/key.
            if host.lastConnectionID == nil {
                items.append(.action(L10n.actionRecoverConnection.localized(), systemImage: "arrow.counterclockwise.circle") {
                    recoverConfirmHost = host
                })
            }
            items.append(.divider)
            items.append(.action(L10n.actionUninstall.localized(), systemImage: "trash", role: .destructive) {
                uninstallConfirmHost = host
            })
        } else {
            items.append(.action(L10n.actionInstall.localized(), systemImage: "arrow.down.app") {
                installFor = host
            })
            items.append(.action(L10n.actionScanVPS.localized(), systemImage: "magnifyingglass") {
                Task { await scanContainers(host) }
            })
        }

        // Deep uninstall whenever there's something to wipe (Podman present).
        if currentBase(host) != .noPodman {
            items.append(.action(L10n.actionDeepUninstall.localized(), systemImage: "flame", role: .destructive) {
                deepUninstallConfirmHost = host
            })
        }

        // #304: share the connection this host owns (URI / QR), moved here from the
        // Connections tab — the connection is configured on this card.
        if let conn = linkedConnection(host) {
            items.append(.divider)
            items.append(.action(L10n.shareConnectionTitle.localized(), systemImage: "square.and.arrow.up") {
                shareConn = conn
            })
            // #135: full-access (co-admin) share — carries the SSH credentials so
            // the recipient can MANAGE the VPS. Destructive; warned in the sheet.
            items.append(.action(L10n.shareFullAccessTitle.localized(), systemImage: "key.horizontal", role: .destructive) {
                if let req = fullAccessRequest(host, conn: conn) { shareFullAccess = req }
            })
        }

        items.append(.divider)
        items.append(.action(L10n.actionReboot.localized(), systemImage: "arrow.clockwise", role: .destructive) {
            rebootConfirmHost = host
        })
        items.append(.divider)
        items.append(.action(L10n.edit.localized(), systemImage: "pencil") { editHost = host })
        items.append(.action(L10n.actionRemoveFromList.localized(), systemImage: "minus.circle", role: .destructive) {
            removeHost = host
        })
        return items
    }

    // MARK: Actions (each drives the card through `run`; the probe sets base)

    private func password(for host: ServerHost) -> String? {
        serverStore.password(for: host)
    }

    /// SSH status probe + TCP ping. The probe is the authoritative base setter.
    private func checkServer(_ host: ServerHost) async {
        Task { await doPing(host) }  // parallel TCP ping; updates the Ping metric
        await run(.check, on: host) { pw in
            let (rstate, stats) = try await provisioner.checkReadiness(
                on: host, password: pw, containerName: host.lastContainerName)
            if let stats { vpsStats[host.id] = stats }
            var base = HostBase(rstate)
            // #302: a check on a host with no *known* container reports "image
            // cached, ready for reinstall" even when an olcrtc container already
            // exists (just stopped) — the user only saw it after manually tapping
            // "Look for olcrtc containers". Fold that scan into the check so an
            // existing container is auto-detected + adopted without the extra step.
            if host.lastContainerName == nil, !base.hasContainer,
               let found = try? await provisioner.scanContainers(on: host, password: pw).first {
                var updated = host
                updated.lastContainerName = found.name
                serverStore.update(updated, password: nil)
                LogStore.shared.log(.provisioning, L10n.autoDetectedContainer_fmt.formatted(found.name))
                if case .running = found.status { base = .running } else { base = .stopped }
            }
            return base
        }
    }

    private func install(_ host: ServerHost, options: InstallOptions) async {
        await run(.install, on: host) { pw in
            let result = try await provisioner.install(on: host, password: pw, options: options)
            let cfg = try OlcrtcURI.parse(result.uri)
            // #355 (audit A1): carry the vp8 + sei tuning the install URI may
            // encode (server-script format) instead of dropping them to
            // defaults; nil payload fields fall back to OlcrtcConnection's own
            // defaults, same as the recover path.
            let params = OlcrtcConnection(
                carrier:      cfg.carrier,
                transport:    cfg.transport,
                roomID:       cfg.roomID,
                key:          cfg.key,
                clientID:     cfg.clientID,
                vp8FPS:       cfg.vp8FPS,
                vp8BatchSize: cfg.vp8BatchSize,
                seiFPS:       cfg.seiFPS   ?? 30,
                seiBatch:     cfg.seiBatch ?? 10,
                seiFrag:      cfg.seiFrag  ?? 1200,
                seiACK:       cfg.seiACK   ?? 1
            )
            let record = ConnectionRecord(name: host.label, details: .olcrtc(params))
            connections.add(record)
            var updated = host
            updated.lastContainerName = result.containerName
            updated.lastConnectionID  = record.id
            serverStore.update(updated, password: nil)
            // #258 was: readiness[id] = .containerRunning("just installed") (optimistic).
            // Confirm the real post-install state with a probe instead.
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: result.containerName)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    private func uninstall(_ host: ServerHost) async {
        await run(.uninstall, on: host) { pw in
            try await provisioner.uninstall(on: host, password: pw,
                                            containerName: host.lastContainerName)
            var updated = host
            updated.lastContainerName = nil
            var removedConnName: String?
            if let connID = updated.lastConnectionID {
                if SettingsStore.shared.autoRemoveConnectionOnUninstall,
                   let conn = connections.connections.first(where: { $0.id == connID }) {
                    removedConnName = conn.displayName
                    connections.remove(id: connID)
                }
                updated.lastConnectionID = nil
            }
            serverStore.update(updated, password: nil)
            if let name = removedConnName {
                LogStore.shared.log(.provisioning, "Connection «\(name)» also removed from list.")
            }
            return .imageReady   // container gone, image still cached (deterministic)
        }
    }

    private func update(_ host: ServerHost) async {
        await run(.update, on: host) { pw in
            try await provisioner.update(on: host, password: pw,
                                         containerName: host.lastContainerName)
            guard let cname = host.lastContainerName else { return nil }
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    private func startContainer(_ host: ServerHost) async {
        await run(.start, on: host) { pw in
            guard let cname = host.lastContainerName else {
                throw ProvisionError.parseFailed(L10n.containerNotInstalled.localized())
            }
            // #258 was: readiness[id] = .containerRunning("starting…") before the probe.
            try await provisioner.start(on: host, password: pw, containerName: cname)
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    private func stop(_ host: ServerHost) async {
        await run(.stop, on: host) { pw in
            guard let cname = host.lastContainerName else {
                throw ProvisionError.parseFailed(L10n.containerNotInstalled.localized())
            }
            // #258 was: readiness[id] = .containerStopped("stopping…") before the probe.
            try await provisioner.stop(on: host, password: pw, containerName: cname)
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    private func deepUninstall(_ host: ServerHost, removeImage: Bool) async {
        await run(.deepUninstall, on: host) { pw in
            try await provisioner.deepUninstall(on: host, password: pw,
                                                containerName: host.lastContainerName,
                                                removeImage: removeImage)
            var updated = host
            updated.lastContainerName = nil
            var removedConnName: String?
            if let connID = updated.lastConnectionID {
                if SettingsStore.shared.autoRemoveConnectionOnUninstall,
                   let conn = connections.connections.first(where: { $0.id == connID }) {
                    removedConnName = conn.displayName
                    connections.remove(id: connID)
                }
                updated.lastConnectionID = nil
            }
            serverStore.update(updated, password: nil)
            let (rstate, _) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: nil)
            if let name = removedConnName {
                LogStore.shared.log(.provisioning, "Connection «\(name)» also removed from list.")
            }
            return HostBase(rstate)
        }
    }

    private func reboot(_ host: ServerHost) async {
        await run(.reboot, on: host) { pw in
            try await provisioner.reboot(on: host, password: pw)
            return nil   // host going down; keep the previous base, user re-checks
        }
    }

    private func reconfigure(_ host: ServerHost, options: InstallOptions) async {
        await run(.reconfigure, on: host) { pw in
            guard let cname = host.lastContainerName else {
                throw ProvisionError.parseFailed(L10n.containerNotInstalled.localized())
            }
            let newURI = try await provisioner.reconfigure(on: host, password: pw,
                                                           containerName: cname, options: options)
            // Update the linked ConnectionRecord with the new room/transport.
            if let uri = newURI,
               let connID = host.lastConnectionID,
               let existing = connections.connections.first(where: { $0.id == connID }),
               case .olcrtc(let oldParams) = existing.details,
               let cfg = try? OlcrtcURI.parse(uri) {
                // #355 (audit A1): carry the sei tuning through the rebuild —
                // these were dropped, resetting SEI to defaults on every
                // reconfigure. Mirror how vp8FPS/vp8BatchSize are preserved.
                let updated = OlcrtcConnection(
                    carrier:      cfg.carrier,
                    transport:    cfg.transport,
                    roomID:       cfg.roomID,
                    key:          cfg.key.isEmpty ? oldParams.key : cfg.key,
                    clientID:     cfg.clientID,
                    vp8FPS:       oldParams.vp8FPS,
                    vp8BatchSize: oldParams.vp8BatchSize,
                    socksUser:    oldParams.socksUser,
                    socksPass:    oldParams.socksPass,
                    seiFPS:       oldParams.seiFPS,
                    seiBatch:     oldParams.seiBatch,
                    seiFrag:      oldParams.seiFrag,
                    seiACK:       oldParams.seiACK
                )
                var updatedRecord = existing
                updatedRecord.details = .olcrtc(updated)
                connections.update(updatedRecord)
            }
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    // MARK: Container scan (no base change → outside `run`)
    // #339 was: fetchLogs(_:) — ran provisioner.containerLogs and presented the
    // ContainerLogsPayload sheet; replaced by the Logs-tab route (the fetch now
    // runs inside LogsView with phase progress, #338).

    // #303: read the deployed server.yaml + ~/.olcrtc_key for `host`'s linked
    // container and add a ConnectionRecord from it — recovers a usable
    // connection when Connections is empty (new device / reinstall) but the
    // server is already running olcrtc. Read-only on the server.
    private func recoverConnection(_ host: ServerHost) async {
        guard let pw = password(for: host) else {
            alertText = L10n.alertPasswordMissingShort.localized(); return
        }
        guard let cname = host.lastContainerName else {
            alertText = L10n.containerNotInstalled.localized(); return
        }
        do {
            let cfg = try await provisioner.recoverConfig(on: host, password: pw, containerName: cname)
            // #303: default-struct values (30/10/1200/1) match OlcrtcConnection's
            // own seiFPS/seiBatch/seiFrag/seiACK defaults (App/Models/OlcrtcConnection.swift)
            // — used as a fallback only if the deployed server.yaml's sei: block
            // somehow lacked a field (shouldn't happen for srv.sh-written configs).
            let params = OlcrtcConnection(
                carrier:      cfg.carrier,
                transport:    cfg.transport,
                roomID:       cfg.roomID,
                key:          cfg.key,
                clientID:     "default",
                vp8FPS:       cfg.vp8FPS,
                vp8BatchSize: cfg.vp8BatchSize,
                seiFPS:       cfg.seiFPS   ?? 30,
                seiBatch:     cfg.seiBatch ?? 10,
                seiFrag:      cfg.seiFrag  ?? 1200,
                seiACK:       cfg.seiACK   ?? 1
            )
            let record = ConnectionRecord(name: host.label, details: .olcrtc(params))
            connections.add(record)
            var updated = host
            updated.lastConnectionID = record.id
            serverStore.update(updated, password: nil)
            alertText = L10n.recoverResultSuccess_fmt.formatted(cfg.carrier, cfg.transport)
        // boc #314: server.yaml unreadable/unparseable — the key/params can't
        // be extracted read-only, so offer the "generate new key" fallback
        // instead of a dead-end error alert. Other errors (SSH, network,
        // missing container) keep the plain alert below.
        } catch let error as SSHRunner.RecoverConfigError {
            LogStore.shared.log(.provisioning,
                "⚠ Recover unusable (\(error.localizedDescription)) — offering key rotation (#314)")
            rotateKeyConfirmHost = host
        // eoc #314
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    // #314: "generate new key" fallback for #303 — rotates ~/.olcrtc_key on the
    // VPS via scripts/rotate-key.sh (repairs server.yaml with srv.sh's exact
    // key/yaml semantics + restarts the container), then adds the resulting
    // connection exactly like a fresh install does (parse OLCRTC_URI=).
    private func rotateKey(_ host: ServerHost) async {
        guard let pw = password(for: host) else {
            alertText = L10n.alertPasswordMissingShort.localized(); return
        }
        guard let cname = host.lastContainerName else {
            alertText = L10n.containerNotInstalled.localized(); return
        }
        do {
            let result = try await provisioner.rotateKey(on: host, password: pw, containerName: cname)
            let cfg = try OlcrtcURI.parse(result.uri)
            // vp8 tuning comes from the URI payload (salvaged server values may
            // differ from this app's global defaults). sei tuning can't round-trip
            // through OlcrtcURI.Parsed — defaults apply, same as the install path.
            let params = OlcrtcConnection(
                carrier:      cfg.carrier,
                transport:    cfg.transport,
                roomID:       cfg.roomID,
                key:          cfg.key,
                clientID:     cfg.clientID,
                vp8FPS:       cfg.vp8FPS,
                vp8BatchSize: cfg.vp8BatchSize
            )
            let record = ConnectionRecord(name: host.label, details: .olcrtc(params))
            connections.add(record)
            var updated = host
            updated.lastContainerName = result.containerName
            updated.lastConnectionID  = record.id
            serverStore.update(updated, password: nil)
            alertText = L10n.rotateKeyResultAdded_fmt.formatted(cfg.carrier, cfg.transport)
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    private func scanContainers(_ host: ServerHost) async {
        guard let pw = password(for: host) else {
            alertText = L10n.alertPasswordMissingShort.localized(); return
        }
        do {
            let found = try await provisioner.scanContainers(on: host, password: pw)
            foundContainers = found
            scanFor = host
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func containerScanSheet(host: ServerHost) -> some View {
        NavigationStack {
            Group {
                if foundContainers.isEmpty {
                    Text(L10n.scanNoContainers.localized())
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List(foundContainers) { container in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(container.name)
                                    .font(.system(.body, design: .monospaced))
                                HStack(spacing: 8) {
                                    Circle()
                                        // #350 was: Color.green / Color.orange — route through Theme.Palette.
                                        .fill(container.status == .notFound ? Color.secondary :
                                              container.status.shortLabel.hasPrefix("Up") ? Theme.Palette.green : Theme.Palette.orange)
                                        .frame(width: 8, height: 8)
                                    Text(container.status.shortLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !container.carrier.isEmpty {
                                        Text("· \(container.carrier)/\(container.transport)")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                if !container.roomID.isEmpty {
                                    Text(L10n.roomPrefix_fmt.formatted(container.roomID))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button(L10n.scanRestoreAction.localized()) {
                                restoreContainer(container, on: host)
                            }
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(L10n.actionScanVPS.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.actionDone.localized()) { scanFor = nil }
                }
            }
        }
        .onDisappear { foundContainers = [] }
        .presentationDetents([.medium, .large])
    }

    private func restoreContainer(_ container: SSHRunner.FoundContainer, on host: ServerHost) {
        scanFor = nil
        var updated = host
        updated.lastContainerName = container.name
        serverStore.update(updated, password: nil)
        display[host.id] = .base(.stopped)   // container present; Check confirms run-state
        alertText = L10n.scanRestored_fmt.formatted(container.name)   // #346 was: "Restored: \(container.name)"
    }
}

// #135: identifiable wrapper so the full-access share can drive a `.sheet(item:)`
// the same way `shareConn` does. Carries the connection (for the URI-only top of
// the sheet) plus the SSH payload that unlocks the destructive opt-in section.
struct FullAccessShareRequest: Identifiable {
    let id = UUID()
    let conn: ConnectionRecord
    let payload: FullAccessShare
}

// #340: both appearance variants.
#if DEBUG
#Preview("Manage VPS — Dark") {
    ServersView(serverStore: ServerHostStore(), connections: ConnectionStore(),
                logsRouter: LogsRouter())
        .preferredColorScheme(.dark)
}
#Preview("Manage VPS — Light") {
    ServersView(serverStore: ServerHostStore(), connections: ConnectionStore(),
                logsRouter: LogsRouter())
        .preferredColorScheme(.light)
}
#endif
