import SwiftUI

// MARK: - BotSettingsView (#419)
//
// Per-server bot sheet — one bot per server. The user picks a bot from the
// Settings registry (`BotStore`), sets the start/stop commands + replies, then
// Checks / Deploys / Removes it on this VPS. Detection probes every registry
// name (`BotStore.markers`); the token comes from the registry (not entered here).

struct BotSettingsView: View {
    let host: ServerHost
    @ObservedObject var botStore: BotStore
    @ObservedObject var provisioner: Provisioner
    let password: String?

    @Environment(\.dismiss) private var dismiss

    // Per-server fields (commands are language-neutral config seeds, like
    // InstallOptions defaults; the replies seed from L10n on a fresh deploy).
    @State private var selectedBotID: UUID?
    @State private var startCmd = "start"
    @State private var stopCmd  = "stop"
    @State private var startReply = ""
    @State private var stopReply  = ""
    @State private var unknownReply = ""
    @State private var isEditing = false

    @State private var deployed: DeployedBot?     // what's currently on this server (nil = none)
    @State private var didInitialCheck = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var confirmRemove = false

    private var selectedBot: BotIdentity? { botStore.bots.first { $0.id == selectedBotID } }
    private var canOperate: Bool { password != nil && !busy }

    var body: some View {
        NavigationStack {
            Form {
                if botStore.bots.isEmpty {
                    emptyRegistrySection
                } else {
                    statusSection
                    botSection
                    commandsSection
                    repliesSection
                    actionsSection
                }
            }
            .navigationTitle(L10n.botSheetTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.close.localized())
                }
            }
            // Auto-detect on open so the fields reflect what's actually on the server.
            .task {
                guard !didInitialCheck else { return }
                didInitialCheck = true
                // #425: only auto-detect when there's something to detect with — a
                // stored password and at least one configured bot. Otherwise just
                // show the state (no SSH round-trip, no password alert on open).
                guard password != nil, !botStore.bots.isEmpty else { return }
                await check()
            }
            .alert(L10n.botRemoveConfirmTitle.localized(), isPresented: $confirmRemove) {
                Button(L10n.botRemoveAction.localized(), role: .destructive) { Task { await remove() } }
                Button(L10n.cancel.localized(), role: .cancel) {}
            } message: {
                Text(L10n.botRemoveConfirmBody.localized())
            }
            .alert(L10n.error.localized(), isPresented: Binding(
                get: { errorText != nil }, set: { if !$0 { errorText = nil } }
            )) {
                Button(L10n.ok.localized()) { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }

    // MARK: Sections

    private var emptyRegistrySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.botNoBotsTitle.localized()).font(.headline)
                Text(L10n.botNoBotsHint.localized())
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Text(statusLabel).foregroundStyle(statusTone)
                Spacer()
                if busy { ProgressView() }
            }
            if let d = deployed, !botStore.bots.contains(where: { $0.name == d.marker }) {
                Text(L10n.botUnknownFound_fmt.formatted(d.marker))
                    .font(.caption).foregroundStyle(Theme.Palette.orange)
            }
            OlcButton(L10n.botCheckAction.localized(),
                      systemImage: "antenna.radiowaves.left.and.right",
                      role: .secondary, isBusy: busy, fillWidth: true) {
                Task { await check() }
            }
            .disabled(!canOperate)
        } header: {
            Text(L10n.botSheetTitle.localized())
        } footer: {
            Text(L10n.botSheetFooter.localized()).font(.caption2)
        }
    }

    private var botSection: some View {
        Section {
            Picker(L10n.botSelectLabel.localized(), selection: Binding(
                get: { selectedBotID ?? botStore.bots.first?.id },
                set: { selectedBotID = $0 }
            )) {
                ForEach(botStore.bots) { bot in
                    Text(bot.name).tag(Optional(bot.id))
                }
            }
            .disabled(!isEditing)
            if let bot = selectedBot {
                HStack {
                    Text(L10n.botPlatformLabel.localized())
                    Spacer()
                    Text(bot.platform.title).foregroundStyle(Theme.Palette.textSecondary)
                }
                Text(botStore.hasToken(bot) ? L10n.botTokenSavedHint.localized()
                                            : L10n.botTokenNoneHint.localized())
                    .font(.caption)
                    .foregroundStyle(botStore.hasToken(bot) ? Theme.Palette.textSecondary
                                                            : Theme.Palette.orange)
            }
        }
    }

    private var commandsSection: some View {
        Section(L10n.botCommandsHeader.localized()) {
            labeledField(L10n.botStartCmdLabel.localized(), text: $startCmd)
            labeledField(L10n.botStopCmdLabel.localized(),  text: $stopCmd)
        }
    }

    private var repliesSection: some View {
        Section(L10n.botRepliesHeader.localized()) {
            labeledField(L10n.botStartReplyLabel.localized(),   text: $startReply)
            labeledField(L10n.botStopReplyLabel.localized(),    text: $stopReply)
            labeledField(L10n.botUnknownReplyLabel.localized(), text: $unknownReply)
        }
    }

    private var actionsSection: some View {
        Section {
            if isEditing {
                OlcButton(deployed == nil ? L10n.botDeployAction.localized() : L10n.save.localized(),
                          systemImage: "arrow.up.circle", role: .primary,
                          isBusy: busy, fillWidth: true) {
                    Task { await deploy() }
                }
                .disabled(!canOperate || selectedBot == nil)
            } else {
                OlcButton(L10n.edit.localized(), systemImage: "pencil",
                          role: .secondary, fillWidth: true) { isEditing = true }
                    .disabled(busy)
            }
            if deployed != nil {
                OlcButton(L10n.botRemoveAction.localized(), systemImage: "trash",
                          role: .danger, fillWidth: true) { confirmRemove = true }
                    .disabled(!canOperate)
            }
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.Palette.textTertiary)
            TextField("", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!isEditing)
                .foregroundStyle(isEditing ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
        }
    }

    private var statusLabel: String {
        guard let d = deployed else { return L10n.botStatusNone.localized() }
        return d.active ? L10n.botStatusRunning.localized() : L10n.botStatusInstalledIdle.localized()
    }

    private var statusTone: Color {
        guard let d = deployed else { return Theme.Palette.textSecondary }
        return d.active ? Theme.Palette.green : Theme.Palette.orange
    }

    // MARK: Operations

    private func check() async {
        guard let pw = password else { errorText = L10n.alertPasswordMissingShort.localized(); return }
        busy = true; defer { busy = false }
        do {
            let found = try await provisioner.checkBots(on: host, password: pw, markers: botStore.markers)
            applyFound(found.first)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Folds a detection result into the editable fields: a found bot → display
    /// mode with its values; nothing found → edit mode seeded for a fresh deploy.
    private func applyFound(_ bot: DeployedBot?) {
        deployed = bot
        if let b = bot {
            if !b.startCmd.isEmpty { startCmd = b.startCmd }
            if !b.stopCmd.isEmpty  { stopCmd  = b.stopCmd }
            startReply   = b.startReply
            stopReply    = b.stopReply
            unknownReply = b.unknownReply
            if let match = botStore.bots.first(where: { $0.name == b.marker }) {
                selectedBotID = match.id
            }
            isEditing = false
        } else {
            if startReply.isEmpty   { startReply   = L10n.botDefaultStartReply.localized() }
            if stopReply.isEmpty    { stopReply    = L10n.botDefaultStopReply.localized() }
            if unknownReply.isEmpty { unknownReply = L10n.botDefaultUnknownReply.localized() }
            if selectedBotID == nil { selectedBotID = botStore.bots.first?.id }
            isEditing = true
        }
    }

    private func deploy() async {
        guard let pw = password else { errorText = L10n.alertPasswordMissingShort.localized(); return }
        guard let bot = selectedBot else { return }
        let token = botStore.token(for: bot)
        guard !token.isEmpty else { errorText = L10n.botMissingTokenError.localized(); return }
        let config = BotDeployConfig(
            marker: bot.name, platform: bot.platform, token: token,
            startCmd: startCmd.trimmingCharacters(in: .whitespaces),
            stopCmd:  stopCmd.trimmingCharacters(in: .whitespaces),
            startReply: startReply, stopReply: stopReply, unknownReply: unknownReply)
        busy = true; defer { busy = false }
        do {
            try await provisioner.deployBot(on: host, password: pw, config: config)
            let found = try await provisioner.checkBots(on: host, password: pw, markers: botStore.markers)
            applyFound(found.first { $0.marker == bot.name } ?? found.first)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove() async {
        guard let pw = password, let d = deployed else { return }
        busy = true; defer { busy = false }
        do {
            try await provisioner.removeBot(on: host, password: pw, marker: d.marker)
            applyFound(nil)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
