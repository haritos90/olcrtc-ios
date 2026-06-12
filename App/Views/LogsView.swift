import SwiftUI

// #316: single-stack Logs tab. #294's per-source rework made LogsView a
// `TabView` nested inside MainTabView's `TabView`, which rendered a second
// tab strip at the bottom, and every tab stacked its own NavigationStack +
// title + description header + file caption before the first log line.
// Now: ONE NavigationStack ("Logs" large title), ONE `.searchable`, ONE
// trailing overflow menu; the category switch is an `OlcSegmented` under the
// search field; a single header row (file name + line count) sits directly
// on top of the log body. Per-line rendering (#276 severity tints, #277
// newest-first dated stamps) and the per-server container buffers/fetch
// (#295/#296/#297) are unchanged.
//
// #316 was: `isActive` (passed from App.swift, unused since #294) — dropped
// together with the per-tab `LogCategoryTabView` / `ContainerLogsTabView`
// wrappers and the `LogTabHeader` (its description now feeds the empty-state
// hint).

struct LogsView: View {
    @ObservedObject private var serverStore: ServerHostStore
    /// #338: needed to spot the primary connection's host (ordered first,
    /// starred) in the container source card.
    @ObservedObject private var connections: ConnectionStore
    /// #339: Manage VPS "Container logs" lands here — select Container + that
    /// host, optionally auto-start the fetch, then clear the request.
    @ObservedObject private var router: LogsRouter
    // #332 was: @ObservedObject private var store = LogStore.shared — every
    // store publish re-evaluated this whole body (toolbar export string +
    // filtered/attributed log text) even while another tab was selected.
    // The store is now read directly; the body refreshes off the coalesced
    // `revision` via `logRefreshTick`, gated on tab visibility below.
    private let store = LogStore.shared
    /// #332: bumped from `store.$revision` (≤4/s) while the tab is visible —
    /// the only log-driven invalidation this view has left.
    @State private var logRefreshTick = 0
    /// #332: Logs is a persistent TabView child; without this gate a hidden
    /// Logs tab would still rebuild on every revision bump.
    @State private var isTabVisible = false
    @StateObject private var provisioner = Provisioner()

    @State private var selection: LogCategory = .connection
    @State private var searchText = ""
    @State private var selectedHostID: UUID?
    // #338 was: fetching: Bool — now the monotonic fetch phase (nil = idle),
    // mirroring the HostDisplay forward-only pattern; drives text + k/n + bar.
    @State private var fetchPhase: Int?
    @State private var alertText: String?  // #297

    /// #338: the three fetch phases (README §2): Connecting… (includes the
    /// scan-first fallback) → the podman command → Receiving output….
    private static let fetchPhaseCount = 3

    init(serverStore: ServerHostStore, connections: ConnectionStore, router: LogsRouter) {
        _serverStore = ObservedObject(wrappedValue: serverStore)
        _connections = ObservedObject(wrappedValue: connections)
        _router      = ObservedObject(wrappedValue: router)
    }

    var body: some View {
        NavigationStack {
            // #332: reading the tick ties this body to the coalesced refresh
            // (the store itself is no longer observed).
            let _ = logRefreshTick
            VStack(spacing: 0) {
                // #316: category switch — short labels so four segments never
                // wrap; the full category names go to VoiceOver.
                OlcSegmented(selection: $selection,
                             options: LogCategory.allCases.map { ($0, $0.segmentTitle, $0.title) })
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 10)

                // #338 was: serverPicker (nav-area menu) + downloadBar (bare
                // right-aligned text button) — replaced by the source card.
                if selection == .containerLogs {
                    containerSourceCard
                }

                fileHeaderRow

                LogBodyView(
                    entries: currentEntries,
                    searchText: searchText,
                    emptySystemImage: selection.systemImage,
                    emptyTitle: L10n.emptyLogsGeneric.localized(),
                    emptyHint: emptyHint,
                    // #338: container empty state gets a primary "Fetch from {host}" CTA.
                    ctaTitle: containerCTAHost.map { L10n.logsFetchFromHost_fmt.formatted($0.label) },
                    ctaSystemImage: "arrow.down.doc",
                    ctaAction: containerCTAHost.map { host in
                        { Task { await primaryAction(host) } }
                    }
                )
            }
            .navigationTitle(L10n.logsTitle.localized())
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L10n.logsSearchPlaceholder.localized())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    let plain = LogRendering.plain(currentEntries.reversed())
                    OlcOverflowMenu(items: [
                        .share(L10n.shareAction.localized(), systemImage: "square.and.arrow.up", item: plain),
                        .action(L10n.copyAllAction.localized(), systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = plain
                        },
                        .divider,
                        .action(L10n.clearCategoryAction.localized(), systemImage: "trash", role: .destructive) {
                            clearCurrent()
                        },
                    ])
                    .disabled(currentEntries.isEmpty)
                }
            }
            // #332: visibility-gated refresh — hidden tabs skip the tick and
            // catch up once in onAppear. `$revision` is already coalesced in
            // LogStore (≤4 bumps/s), so a teardown log storm costs the UI at
            // most four body re-evaluations per second, and zero when hidden.
            .onReceive(store.$revision) { _ in
                if isTabVisible { logRefreshTick &+= 1 }
            }
            .onDisappear { isTabVisible = false }  // #332
            // #339: consume a Manage VPS → Logs route. onChange covers the
            // already-mounted view; onAppear covers a LogsView first created
            // by the tab switch itself (request set before it existed).
            .onChange(of: router.request) { _, req in
                consumeLogsRequest(req)
            }
            .onAppear {
                isTabVisible = true     // #332
                logRefreshTick &+= 1    // #332: render lines logged while hidden
                consumeLogsRequest(router.request)
            }
            // #338: advance the fetch phase forward-only from the provisioner's
            // real progress signals — the podman command starting (SSHRunner
            // step) and the output-received marker; the scan-first fallback's
            // own steps deliberately stay in phase 1 ("Connecting…").
            .onChange(of: provisioner.status) { _, status in
                guard fetchPhase != nil, case .running(let msg) = status else { return }
                if msg.hasPrefix("podman logs") {
                    fetchPhase = max(fetchPhase ?? 0, 1)
                } else if msg == L10n.logsPhaseReceiving.localized() {
                    fetchPhase = max(fetchPhase ?? 0, 2)
                }
            }
            // #297: surface scan/download failures instead of a silent no-op
            // that looked like the button had frozen.
            .alert(L10n.okPrompt.localized(), isPresented: Binding(
                get: { alertText != nil },
                set: { if !$0 { alertText = nil } }
            )) {
                Button(L10n.ok.localized()) { alertText = nil }
            } message: {
                Text(alertText ?? "")
            }
        }
    }

    /// #339: apply a routed request — Container category + that host — and
    /// kick off the fetch when asked (skipped if one is already running).
    /// Idempotent: clears the request first, so the onChange/onAppear pair
    /// can't double-consume.
    private func consumeLogsRequest(_ req: LogsRouter.Request?) {
        guard let req else { return }
        router.request = nil
        selection = .containerLogs
        selectedHostID = req.hostID
        guard req.autofetch, fetchPhase == nil,
              let host = serverStore.hosts.first(where: { $0.id == req.hostID }) else { return }
        Task { await primaryAction(host) }
    }

    // MARK: Current category plumbing (#316)

    /// The buffer behind the selected segment — the category buffer, or the
    /// selected host's per-server container buffer (#295).
    private var currentEntries: [LogEntry] {
        if selection == .containerLogs {
            guard let host = selectedHost else { return [] }
            return store.containerEntries[host.logFilePrefix] ?? []
        }
        return store.entries[selection] ?? []
    }

    private var currentFileName: String {
        if selection == .containerLogs {
            guard let host = selectedHost else { return "—_container.log" }
            return "\(host.logFilePrefix)_container.log"
        }
        return selection.logFileName
    }

    /// #316: LogTabHeader's per-category description moved into the empty state.
    private var emptyHint: String {
        selection == .containerLogs
            ? L10n.logsContainerEmptyHint.localized()
            : "\(selection.tabDescription). \(L10n.emptyLogsGenericHint.localized())"
    }

    private func clearCurrent() {
        if selection == .containerLogs {
            if let host = selectedHost {
                LogStore.shared.clearContainer(serverPrefix: host.logFilePrefix)
            }
        } else {
            LogStore.shared.clear(category: selection)
        }
    }

    /// #316: the ONE header row, attached to the top of the log body —
    /// `doc.text` + monospaced file name + right-aligned line count.
    private var fileHeaderRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(currentFileName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer(minLength: 8)
                Text(L10n.logsLineCount_fmt.formatted(currentEntries.count))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider().overlay(Theme.Palette.separator)
        }
    }

    // MARK: Container source (#295/#296 — unchanged behaviour, new home)

    /// The host whose container log is shown: the explicit selection, falling
    /// back to the last-fetched target (#278), falling back to the first
    /// configured host.
    private var selectedHost: ServerHost? {
        if let id = selectedHostID, let h = serverStore.hosts.first(where: { $0.id == id }) {
            return h
        }
        if let target = store.lastContainerTarget,
           let h = serverStore.hosts.first(where: { $0.id == target.hostID }) {
            return h
        }
        return serverStore.hosts.first
    }

    /// #338: hosts for the picker — the primary connection's host first
    /// (starred), the rest in store order.
    private var orderedHosts: [ServerHost] {
        guard let pid = connections.primary?.id,
              let i = serverStore.hosts.firstIndex(where: { $0.lastConnectionID == pid })
        else { return serverStore.hosts }
        var hosts = serverStore.hosts
        let primary = hosts.remove(at: i)
        return [primary] + hosts
    }

    private func hostLabel(_ host: ServerHost) -> String {
        host.lastConnectionID != nil && host.lastConnectionID == connections.primary?.id
            ? "★ \(host.label)" : host.label
    }

    /// #338: the host the empty-state "Fetch from {host}" CTA targets —
    /// container category only, with a host, while idle.
    private var containerCTAHost: ServerHost? {
        guard selection == .containerLogs, fetchPhase == nil else { return nil }
        return selectedHost
    }

    /// #338: source card (README §2) — host chips (≤3; Menu picker beyond) +
    /// one secondary Fetch button, with the monotonic phase progress while a
    /// fetch runs. Replaces the #296 bare text button.
    private var containerSourceCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: 10) {
                if serverStore.hosts.isEmpty {
                    Text(L10n.logsContainerNoServers.localized())
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        hostPicker
                        Spacer(minLength: 8)
                        fetchButton
                    }
                    if let phase = fetchPhase {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(phaseText(phase))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("\(min(phase + 1, Self.fetchPhaseCount))/\(Self.fetchPhaseCount)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                            OlcProgressBar(fraction: Double(min(phase + 1, Self.fetchPhaseCount))
                                                   / Double(Self.fetchPhaseCount))
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: fetchPhase != nil)
    }

    @ViewBuilder
    private var hostPicker: some View {
        if orderedHosts.count <= 3 {
            OlcChipPicker(selection: Binding(
                get: { selectedHost?.id },
                set: { selectedHostID = $0 }
            ), options: orderedHosts.map { ($0.id as UUID?, hostLabel($0)) })
        } else {
            Picker(L10n.logsContainerSelectServer.localized(), selection: Binding(
                get: { selectedHost?.id },
                set: { selectedHostID = $0 }
            )) {
                ForEach(orderedHosts) { host in
                    Text(hostLabel(host)).tag(Optional(host.id))
                }
            }
            .pickerStyle(.menu)
        }
    }

    /// #296: always-present action — "Fetch" once the host has a known
    /// container, otherwise "Check server" (scan-first fallback, run inside
    /// `primaryAction`).
    @ViewBuilder
    private var fetchButton: some View {
        if let host = selectedHost {
            let unprobed = host.lastContainerName == nil
            OlcButton(unprobed ? L10n.logsCheckServer.localized() : L10n.logsFetchAction.localized(),
                      systemImage: unprobed ? "antenna.radiowaves.left.and.right" : "arrow.down.doc",
                      role: .secondary,
                      isBusy: fetchPhase != nil) {
                Task { await primaryAction(host) }
            }
        }
    }

    private func phaseText(_ phase: Int) -> String {
        switch phase {
        case 0:  return L10n.logsPhaseConnecting.localized()
        case 1:  return L10n.logsPhaseCommand_fmt.formatted(
                     SettingsStore.shared.containerLogsTailLines,
                     selectedHost?.lastContainerName ?? "olcrtc")
        default: return L10n.logsPhaseReceiving.localized()
        }
    }

    /// #296: the button never blocks the UI — it kicks off a `Task` and
    /// returns immediately; `fetching` drives the spinner. #297: every dead
    /// end now sets `alertText` instead of returning silently, so a tap
    /// always ends in either new log lines or a visible reason it didn't.
    private func primaryAction(_ host: ServerHost) async {
        guard let pw = serverStore.password(for: host) else {
            alertText = L10n.alertPasswordMissingShort.localized(); return
        }
        // #338 was: fetching = true … defer { fetching = false }
        fetchPhase = 0
        defer { fetchPhase = nil }

        var target = host
        if target.lastContainerName == nil {
            // "Check server": probeReadiness(containerName: nil) can never
            // report a container name (#297 was: relied on it to do so, so
            // this branch was a no-op dead end). Scan for an existing olcrtc
            // container instead, mirroring #302's ServersView fold-in.
            do {
                guard let found = try await provisioner.scanContainers(on: target, password: pw).first else {
                    alertText = L10n.scanNoContainers.localized(); return
                }
                target.lastContainerName = found.name
                serverStore.update(target, password: nil)
            } catch {
                alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription); return
            }
        }

        guard let cname = target.lastContainerName else { return }
        do {
            _ = try await provisioner.containerLogs(
                on: target, password: pw, containerName: cname,
                tail: SettingsStore.shared.containerLogsTailLines)
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }
}

// MARK: - Shared rendering helpers

/// Newest-first (#277), colour-coded (#276) rendering of a list of `LogEntry`
/// plus the matching plain-text export, filtered by `searchText`.
@MainActor
enum LogRendering {
    static func filtered(_ entries: [LogEntry], search: String) -> [LogEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = entries.reversed()
        guard !q.isEmpty else { return Array(ordered) }
        return ordered.filter { e in
            e.text.localizedStandardContains(q)
                || LogStore.format(date: e.date).localizedStandardContains(q)
        }
    }

    // boc #332
    /// Rendering cap, independent of the in-memory buffer cap
    /// (`SettingsStore.logBufferSize`): the monolithic `attributed` rebuild is
    /// O(rendered lines) per refresh, so capping what's rendered keeps each
    /// refresh flat no matter how large the buffer grows. Share / Copy / the
    /// on-disk files keep the full history.
    static let renderCap = 500

    /// Newest `renderCap` of an already newest-first list (`filtered` output).
    static func capped(_ entries: [LogEntry]) -> [LogEntry] {
        entries.count > renderCap ? Array(entries.prefix(renderCap)) : entries
    }
    // eoc #332

    static func attributed(_ entries: [LogEntry]) -> AttributedString {
        var attr = AttributedString()
        for e in entries {
            let ts = LogStore.format(date: e.date)
            var stamp = AttributedString("\(ts)  ")
            stamp.foregroundColor = Theme.Palette.textTertiary
            var msg = AttributedString("\(e.text)\n")
            msg.foregroundColor = tint(e.level)
            attr.append(stamp)
            attr.append(msg)
        }
        return attr
    }

    static func plain(_ entries: [LogEntry]) -> String {
        entries.map { "\(LogStore.format(date: $0.date)) \($0.text)" }.joined(separator: "\n")
    }

    static func tint(_ level: LogLineLevel) -> Color {
        switch level {
        case .error: return Theme.Palette.red
        case .warn:  return Theme.Palette.orange
        case .info:  return Theme.Palette.textSecondary
        case .debug: return Theme.Palette.textTertiary
        }
    }
}

/// The scrollable log body: empty state, search-results empty state, or the
/// colour-coded newest-first text.
struct LogBodyView: View {
    let entries: [LogEntry]
    let searchText: String
    let emptySystemImage: String
    let emptyTitle: String
    let emptyHint: String
    // #338: optional CTA on the (non-search) empty state — Container's
    // "Fetch from {host}" primary button.
    var ctaTitle: String? = nil
    var ctaSystemImage: String? = nil
    var ctaAction: (() -> Void)? = nil

    var body: some View {
        let items = LogRendering.filtered(entries, search: searchText)
        if items.isEmpty {
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            OlcEmptyState(
                systemImage: isSearching ? "magnifyingglass" : emptySystemImage,
                title: isSearching ? L10n.noSearchResults.localized() : emptyTitle,
                hint: isSearching
                      ? L10n.noSearchResultsHint_fmt.formatted(searchText)
                      : emptyHint,
                ctaTitle: isSearching ? nil : ctaTitle,        // #338
                ctaSystemImage: ctaSystemImage,
                action: ctaAction
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // boc #332: render only the newest `renderCap` lines, with a
            // truncation notice on top (the list is newest-first) pointing at
            // Share/Copy for the full history.
            let visible = LogRendering.capped(items)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if visible.count < items.count {
                        Text(L10n.logsRenderTruncated_fmt.formatted(visible.count))
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Text(LogRendering.attributed(visible))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            // eoc #332
        }
    }
}

// #316 was: `LogTabHeader` (description + "File: x.log" caption above every
// tab), `LogCategoryTabView` (per-category NavigationStack + searchable +
// toolbar) and `ContainerLogsTabView` (the same plus host picker, download
// bar and the #296/#297 fetch logic) — all folded into the single-stack
// `LogsView` above; the fetch logic moved verbatim.

// #340: both appearance variants.
#if DEBUG
#Preview("Logs — Dark") {
    LogsView(serverStore: ServerHostStore(), connections: ConnectionStore(),
             router: LogsRouter())
        .preferredColorScheme(.dark)
}
#Preview("Logs — Light") {
    LogsView(serverStore: ServerHostStore(), connections: ConnectionStore(),
             router: LogsRouter())
        .preferredColorScheme(.light)
}
#endif
